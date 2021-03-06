require 'email/html_cleaner'
#
# Handles an incoming message
#

module Email

  class Receiver

    include ActionView::Helpers::NumberHelper

    class ProcessingError < StandardError; end
    class EmailUnparsableError < ProcessingError; end
    class EmptyEmailError < ProcessingError; end
    class UserNotFoundError < ProcessingError; end
    class UserNotSufficientTrustLevelError < ProcessingError; end
    class BadDestinationAddress < ProcessingError; end
    class TopicNotFoundError < ProcessingError; end
    class TopicClosedError < ProcessingError; end
    class EmailLogNotFound < ProcessingError; end
    class InvalidPost < ProcessingError; end

    attr_reader :body, :email_log

    def initialize(raw)
      @raw = raw
    end

    def process
      raise EmptyEmailError if @raw.blank?

      message = Mail.new(@raw)

      body = parse_body message

      dest_info = {type: :invalid, obj: nil}
      message.to.each do |to_address|
        if dest_info[:type] == :invalid
          dest_info = check_address to_address
        end
      end

      raise BadDestinationAddress if dest_info[:type] == :invalid
      raise TopicNotFoundError if message.header.to_s =~ /auto-generated/ || message.header.to_s =~ /auto-replied/

      # TODO get to a state where we can remove this
      @message = message
      @body = body

      if dest_info[:type] == :category
        raise BadDestinationAddress unless SiteSetting.email_in
        category = dest_info[:obj]
        @category_id = category.id
        @allow_strangers = category.email_in_allow_strangers

        user_email = @message.from.first
        @user = User.find_by_email(user_email)
        if @user.blank? && @allow_strangers

          wrap_body_in_quote user_email
          # TODO This is WRONG it should register an account
          # and email the user details on how to log in / activate
          @user = Discourse.system_user
        end

        raise UserNotFoundError if @user.blank?
        raise UserNotSufficientTrustLevelError.new @user unless @allow_strangers || @user.has_trust_level?(TrustLevel[SiteSetting.email_in_min_trust.to_i])

        create_new_topic
      else
        @email_log = dest_info[:obj]

        raise EmailLogNotFound if @email_log.blank?
        raise TopicNotFoundError if Topic.find_by_id(@email_log.topic_id).nil?
        raise TopicClosedError if Topic.find_by_id(@email_log.topic_id).closed?

        create_reply
      end
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
      raise EmailUnparsableError.new(e)
    end

    def check_address(address)
      category = Category.find_by_email(address)
      return {type: :category, obj: category} if category

      regex = Regexp.escape SiteSetting.reply_by_email_address
      regex = regex.gsub(Regexp.escape('%{reply_key}'), "(.*)")
      regex = Regexp.new regex
      match = regex.match address
      if match && match[1].present?
        reply_key = match[1]
        email_log = EmailLog.for(reply_key)

        return {type: :reply, obj: email_log}
      end

      {type: :invalid, obj: nil}
    end

    def parse_body(message)
      body = select_body message
      encoding = body.encoding
      raise EmptyEmailError if body.strip.blank?

      body = discourse_email_trimmer body
      raise EmptyEmailError if body.strip.blank?

      body = EmailReplyParser.parse_reply body
      raise EmptyEmailError if body.strip.blank?

      body.force_encoding(encoding).encode("UTF-8")
    end

    def select_body(message)
      html = nil
      # If the message is multipart, return that part (favor html)
      if message.multipart?
        html = fix_charset message.html_part
        text = fix_charset message.text_part

        # prefer plain text
        if text
          return text
        end
      elsif message.content_type =~ /text\/html/
        html = fix_charset message
      end

      if html
        body = HtmlCleaner.new(html).output_html
      else
        body = fix_charset message
      end

      # Certain trigger phrases that means we didn't parse correctly
      if body =~ /Content\-Type\:/ || body =~ /multipart\/alternative/ || body =~ /text\/plain/
        raise EmptyEmailError
      end

      body
    end

    # Force encoding to UTF-8 on a Mail::Message or Mail::Part
    def fix_charset(object)
      return nil if object.nil?

      if object.charset
        object.body.decoded.force_encoding(object.charset).encode("UTF-8").to_s
      else
        object.body.to_s
      end
    end

    REPLYING_HEADER_LABELS = ['From', 'Sent', 'To', 'Subject', 'Reply To', 'Cc', 'Bcc', 'Date']
    REPLYING_HEADER_REGEX = Regexp.union(REPLYING_HEADER_LABELS.map { |lbl| "#{lbl}:" })

    def discourse_email_trimmer(body)
      lines = body.scrub.lines.to_a
      range_end = 0

      lines.each_with_index do |l, idx|
        break if l =~ /\A\s*\-{3,80}\s*\z/ ||
                 l =~ Regexp.new("\\A\\s*" + I18n.t('user_notifications.previous_discussion') + "\\s*\\Z") ||
                 (l =~ /via #{SiteSetting.title}(.*)\:$/) ||
                 # This one might be controversial but so many reply lines have years, times and end with a colon.
                 # Let's try it and see how well it works.
                 (l =~ /\d{4}/ && l =~ /\d:\d\d/ && l =~ /\:$/) ||
                 (l =~ /On \w+ \d+,? \d+,?.*wrote:/)

        # Headers on subsequent lines
        break if (0..2).all? { |off| lines[idx+off] =~ REPLYING_HEADER_REGEX }
        # Headers on the same line
        break if REPLYING_HEADER_LABELS.count { |lbl| l.include? lbl } >= 3

        range_end = idx
      end

      lines[0..range_end].join.strip
    end

    def wrap_body_in_quote(user_email)
      @body = "[quote=\"#{user_email}\"]
#{@body}
[/quote]"
    end

    private

    def create_reply
      create_post_with_attachments(@email_log.user,
                                   raw: @body,
                                   topic_id: @email_log.topic_id,
                                   reply_to_post_number: @email_log.post.post_number)
    end

    def create_new_topic
      post = create_post_with_attachments(@user,
                                          raw: @body,
                                          title: @message.subject,
                                          category: @category_id)

      EmailLog.create(
        email_type: "topic_via_incoming_email",
        to_address: @message.from.first, # pick from address because we want the user's email
        topic_id: post.topic.id,
        user_id: @user.id,
      )

      post
    end

    def create_post_with_attachments(user, post_opts={})
      options = {
        cooking_options: { traditional_markdown_linebreaks: true },
      }.merge(post_opts)

      raw = options[:raw]

      # deal with attachments
      @message.attachments.each do |attachment|
        tmp = Tempfile.new("discourse-email-attachment")
        begin
          # read attachment
          File.open(tmp.path, "w+b") { |f| f.write attachment.body.decoded }
          # create the upload for the user
          upload = Upload.create_for(user.id, tmp, attachment.filename, File.size(tmp))
          if upload && upload.errors.empty?
            # TODO: should use the same code as the client to insert attachments
            raw << "\n#{attachment_markdown(upload)}\n"
          end
        ensure
          tmp.close!
        end
      end

      options[:raw] = raw

      create_post(user, options)
    end

    def attachment_markdown(upload)
      if FileHelper.is_image?(upload.original_filename)
        "<img src='#{upload.url}' width='#{upload.width}' height='#{upload.height}'>"
      else
        "<a class='attachment' href='#{upload.url}'>#{upload.original_filename}</a> (#{number_to_human_size(upload.filesize)})"
      end
    end

    def create_post(user, options)
      # Mark the reply as incoming via email
      options[:via_email] = true
      options[:raw_email] = @raw

      creator = PostCreator.new(user, options)
      post = creator.create

      if creator.errors.present?
        raise InvalidPost, creator.errors.full_messages.join("\n")
      end

      post
    end

  end
end
