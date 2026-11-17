# frozen_string_literal: true

require "openssl"

module Locentra
  module Infrastructure
    # Cifragem autenticada (AES-256-GCM via OpenSSL) para segredos que precisam ser recuperados,
    # como o segredo de assinatura de webhooks. A chave é derivada por HKDF da chave configurada.
    class SecretBox
      VERSION = "v1"

      def initialize(key_material)
        raise ArgumentError, "chave de cifragem ausente" if key_material.to_s.length < 16

        @key = OpenSSL::KDF.hkdf(key_material.to_s, salt: "locentra-secret-box", info: "#{VERSION}:aes-256-gcm", length: 32, hash: "SHA256")
      end

      def encrypt(plaintext)
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = @key
        iv = cipher.random_iv
        cipher.auth_data = VERSION
        ciphertext = cipher.update(plaintext.to_s) + cipher.final
        "#{VERSION}.#{[iv + cipher.auth_tag + ciphertext].pack("m0")}"
      end

      def decrypt(text)
        version, payload = text.to_s.split(".", 2)
        raise ArgumentError, "formato de segredo desconhecido" unless version == VERSION && payload

        raw = payload.unpack1("m0")
        decipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        decipher.key = @key
        decipher.iv = raw[0, 12]
        decipher.auth_tag = raw[12, 16]
        decipher.auth_data = VERSION
        decipher.update(raw[28..]) + decipher.final
      rescue OpenSSL::Cipher::CipherError
        raise ArgumentError, "segredo corrompido ou chave incorreta"
      end
    end

    # Assinatura de webhooks enviados: HMAC-SHA256 sobre "timestamp.corpo".
    module WebhookSignature
      module_function

      def header(secret, timestamp, body)
        "t=#{timestamp},v1=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")}"
      end

      def valid?(secret, header, body, now:, tolerance: 300)
        parts = header.to_s.split(",").to_h { |pair| pair.split("=", 2) }
        timestamp = Integer(parts["t"].to_s, 10)
        return false if (now.to_i - timestamp).abs > tolerance

        expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
        OpenSSL.fixed_length_secure_compare(expected, parts["v1"].to_s)
      rescue ArgumentError
        false
      end
    end
  end
end
