# frozen_string_literal: true

require "mail"
require "openssl"

module Locentra
  module Infrastructure
    # Envio de e-mail por SMTP com a gem `mail` (composição MIME e proteção de cabeçalhos).
    #
    # `tls`: "none" (somente relay local, como o Mailpit), "starttls" (STARTTLS obrigatório: o envio
    # falha se o servidor não oferecer) ou "tls" (TLS implícito na conexão, porta 465). Certificado
    # verificado. Com `user_name`, autentica com `authentication` (plain, login ou cram_md5).
    class SmtpMailer
      TLS = {
        "none" => { enable_starttls_auto: false },
        "starttls" => { enable_starttls: true, openssl_verify_mode: OpenSSL::SSL::VERIFY_PEER },
        "tls" => { tls: true, openssl_verify_mode: OpenSSL::SSL::VERIFY_PEER }
      }.freeze

      attr_reader :settings

      def initialize(host:, port:, from:, tls: "none", user_name: nil, password: nil, authentication: "plain", open_timeout: 5, read_timeout: 10)
        @settings = { address: host, port: port, open_timeout: open_timeout, read_timeout: read_timeout }.merge(TLS.fetch(tls))
        @settings.merge!(user_name: user_name, password: password, authentication: authentication.to_sym) if user_name
        @settings.freeze
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
