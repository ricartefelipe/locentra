# frozen_string_literal: true

require "openssl"

module Locentra
  module Infrastructure
    # Cifragem autenticada (AES-256-GCM via OpenSSL) para segredos que precisam ser recuperados,
    # como o segredo de assinatura de webhooks. A chave é derivada por HKDF da chave configurada.
    #
    # Rotação: `previous` recebe chaves anteriores (APP_ENCRYPTION_KEY_PREVIOUS). A cifragem usa sempre
    # a chave atual; a decifragem tenta a atual e depois as anteriores, de modo que a troca da chave não
    # interrompe webhooks nem chamadas ao provedor. `reencrypt` regrava um valor com a chave atual
    # (bin/locentra-admin secrets:reencrypt), depois do que as chaves anteriores podem ser removidas.
    class SecretBox
      VERSION = "v1"

      def initialize(key_material, previous: [])
        @key = derive(key_material)
        @previous = Array(previous).map { |material| derive(material) }
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
        raw = unpack(text)
        [@key, *@previous].each do |key|
          return open_with(key, raw)
        rescue OpenSSL::Cipher::CipherError
          next
        end
        raise ArgumentError, "segredo corrompido ou chave incorreta"
      end

      # Verdadeiro quando o valor já está cifrado com a chave atual.
      def current?(text)
        open_with(@key, unpack(text))
        true
      rescue OpenSSL::Cipher::CipherError
        false
      end

      def reencrypt(text) = encrypt(decrypt(text))

      private

      def derive(material)
        raise ArgumentError, "chave de cifragem ausente" if material.to_s.length < 16

        OpenSSL::KDF.hkdf(material.to_s, salt: "locentra-secret-box", info: "#{VERSION}:aes-256-gcm", length: 32, hash: "SHA256")
      end

      def unpack(text)
        version, payload = text.to_s.split(".", 2)
        raise ArgumentError, "formato de segredo desconhecido" unless version == VERSION && payload

        payload.unpack1("m0")
      end

      def open_with(key, raw)
        decipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        decipher.key = key
        decipher.iv = raw[0, 12]
        decipher.auth_tag = raw[12, 16]
        decipher.auth_data = VERSION
        decipher.update(raw[28..]) + decipher.final
      end
    end

    # Regrava com a chave atual os segredos cifrados de todas as organizações (segredos de webhook e
    # chaves de API dos provedores), organização por organização com o contexto de tenant. Executado
    # com o papel do worker, que lê a lista de organizações. Idempotente: valores já cifrados com a
    # chave atual não são alterados.
    class SecretRotation
      COLUMNS = { "webhook_endpoints" => "secret_ciphertext", "payment_provider_accounts" => "api_key_ciphertext" }.freeze

      def initialize(transactor:, box:)
        @transactor = transactor
        @box = box
      end

      def call
        organizations = @transactor.call { |tx| tx.query("SELECT id FROM organizations ORDER BY id").map { |row| row["id"] } }
        totals = COLUMNS.keys.to_h { |table| [table, 0] }
        organizations.each do |organization_id|
          @transactor.call(tenant_id: organization_id) do |tx|
            COLUMNS.each { |table, column| totals[table] += rotate(tx, organization_id, table, column) }
          end
        end
        totals
      end

      private

      def rotate(tx, organization_id, table, column)
        rows = tx.query("SELECT id, #{column} AS value FROM #{table} WHERE organization_id = $1 AND #{column} IS NOT NULL FOR UPDATE",
                        [organization_id])
        rows.count do |row|
          next false if @box.current?(row["value"])

          tx.execute("UPDATE #{table} SET #{column} = $3 WHERE organization_id = $1 AND id = $2", [organization_id, row["id"], @box.reencrypt(row["value"])])
          true
        end
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
