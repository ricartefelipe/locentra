# frozen_string_literal: true

require "mail"

module Locentra
  module Infrastructure
    # Envio de e-mail por SMTP com a gem `mail` (composição MIME e proteção de cabeçalhos).
    class SmtpMailer
      def initialize(host:, port:, from:, open_timeout: 5, read_timeout: 10)
        @settings = { address: host, port: port, open_timeout: open_timeout, read_timeout: read_timeout,
                      enable_starttls_auto: false }
        @from = from
      end

      def deliver(to:, subject:, text:, attachments: [])
        message = build(to: to, subject: subject, text: text, attachments: attachments)
        message.delivery_method(:smtp, @settings)
        message.deliver!
        message.message_id
      end

      def build(to:, subject:, text:, attachments: [])
        raise ArgumentError, "assunto inválido" if subject.to_s.match?(/[\r\n]/)

        from = @from
        message = Mail.new do
          from from
          to Domain::Identity::Email.normalize(to)
          subject subject.to_s[0, 200]
          text_part do
            content_type "text/plain; charset=UTF-8"
            body text
          end
        end
        attachments.each { |file| message.attachments[file.fetch(:filename)] = { mime_type: file.fetch(:content_type), content: file.fetch(:content) } }
        message
      end
    end
  end
end
