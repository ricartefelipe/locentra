# frozen_string_literal: true

module Locentra
  module Application
    module Attachments
      # Erros da porta de armazenamento (`put/get/delete/exist?`), levantados pelos adaptadores: a
      # aplicação não depende das classes de infraestrutura.
      class InvalidStorageKey < StandardError; end
      class ContentMissing < StandardError; end

      # Tipos aceitos, identificados pelos bytes iniciais do conteúdo (o tipo declarado pelo cliente
      # não é usado para decidir).
      SIGNATURES = {
        "application/pdf" => ->(b) { b.start_with?("%PDF-") },
        "image/png" => ->(b) { b.start_with?("\x89PNG\r\n\x1A\n".b) },
        "image/jpeg" => ->(b) { b.start_with?("\xFF\xD8\xFF".b) },
        "image/webp" => ->(b) { b.byteslice(0, 4) == "RIFF" && b.byteslice(8, 4) == "WEBP" }
      }.freeze
      PERMISSIONS = {
        "contract" => %w[contracts.read contracts.write], "quote" => %w[quotes.read quotes.write],
        "damage_report" => %w[fulfillment.write inspections.write], "return" => %w[fulfillment.write fulfillment.write],
        "maintenance_order" => %w[catalog.read maintenance.write], "customer" => %w[customers.read customers.write]
      }.freeze

      module Rules
        module_function

        def detect_type(bytes)
          SIGNATURES.find { |_, matcher| matcher.call(bytes.b) }&.first
        end

        def sanitize_filename(name)
          text = name.to_s.dup.force_encoding(Encoding::UTF_8).scrub("_")
          base = File.basename(text.tr("\\", "/")).gsub(/[\x00-\x1F\x7F"]/, "").strip
          base = base.unicode_normalize(:nfc)[0, 200]
          base.empty? || base.start_with?(".") ? "arquivo" : base
        end
      end

      # Regras do dono executadas antes de anexar ou remover: `guards` mapeia o tipo de dono para um
      # objeto com `editable!(tx, owner_id)`, que bloqueia o dono e recusa alterações quando o registro
      # não aceita mais mudanças nas evidências (por exemplo, avaria já decidida).
      module OwnerGuard
        private

        def guard!(tx, owner_type, owner_id)
          @guards[owner_type]&.editable!(tx, owner_id)
        end
      end

      class Upload
        include OwnerGuard

        def initialize(uow:, attachments:, storage:, audit:, clock:, ids:, max_bytes:, guards: {})
          @uow = uow
          @attachments = attachments
          @storage = storage
          @audit = audit
          @clock = clock
          @ids = ids
          @max_bytes = max_bytes
          @guards = guards
        end

        # O arquivo é gravado antes do registro; se a transação falhar, o arquivo é removido.
        def call(actor, owner_type:, owner_id:, filename:, bytes:, retain_days: nil, tx: nil)
          raise Domain::ValidationError.field("arquivo", "tipo de anexo inválido") unless PERMISSIONS.key?(owner_type)
          raise Domain::ValidationError.field("arquivo", "arquivo vazio") if bytes.nil? || bytes.empty?
          raise Domain::ValidationError.field("arquivo", "acima de #{@max_bytes / 1_048_576} MB") if bytes.bytesize > @max_bytes

          content_type = Rules.detect_type(bytes) || raise(Domain::ValidationError.field("arquivo", "use PDF, PNG, JPEG ou WebP"))
          return store(tx, actor, owner_type, owner_id, filename, bytes, content_type, retain_days) if tx

          @uow.run(actor, PERMISSIONS.fetch(owner_type).last) do |t, current|
            store(t, current, owner_type, owner_id, filename, bytes, content_type, retain_days)
          end
        end

        private

        def store(tx, actor, owner_type, owner_id, filename, bytes, content_type, retain_days)
          id = @ids.uuid
          key = "#{tx.tenant_id!}/#{id}"
          now = @clock.now
          row = { "id" => id, "owner_type" => owner_type, "owner_id" => Domain::Identifier.parse(owner_id, "dono"),
                  "filename" => Rules.sanitize_filename(filename), "content_type" => content_type, "storage_key" => key,
                  "created_by" => actor.audit_actor_id, "created_at" => now, "retain_until" => retain_days ? now + (retain_days * 86_400) : nil }
          guard!(tx, owner_type, row["owner_id"])
          stats = @storage.put(key, bytes)
          # Composto com outra operação (ex.: PDF do contrato), uma falha posterior, no COMMIT ou uma
          # nova tentativa da transação também removem o arquivo.
          tx.after_rollback { @storage.delete(key) }
          begin
            row = row.merge("byte_size" => stats[:byte_size], "sha256" => stats[:sha256])
            @attachments.insert(tx, row)
            @audit.record(tx, actor, "attachment.uploaded", owner_type, row["owner_id"], "attachment_id" => id, "sha256" => stats[:sha256])
          rescue StandardError
            @storage.delete(key)
            raise
          end
          row
        end
      end

      # Download autenticado: o anexo é buscado pelo id dentro do tenant e a permissão depende do dono.
      # Clientes do portal só acessam o que o escopo do portal permitir (`customer_owns?(tx,
      # customer_id, anexo)`): documentos de contratos próprios. Qualquer outro caso é "não encontrado".
      class Download
        def initialize(uow:, attachments:, storage:, portal_scope:)
          @uow = uow
          @attachments = attachments
          @storage = storage
          @portal_scope = portal_scope
        end

        def call(actor, attachment_id)
          row = @uow.run(actor) do |tx, current|
            found = @attachments.find(tx, Domain::Identifier.parse(attachment_id)) || raise(Domain::NotFound, "anexo")
            authorize!(tx, current, found)
            found
          end
          [row, @storage.get(row["storage_key"])]
        rescue InvalidStorageKey, ContentMissing
          raise Domain::NotFound, "anexo"
        end

        private

        def authorize!(tx, actor, row)
          if actor.customer?
            raise Domain::NotFound, "anexo" unless @portal_scope.customer_owns?(tx, actor.customer_id, row)
          else
            Authorizer.authorize!(actor, PERMISSIONS.fetch(row["owner_type"]).first)
          end
        end
      end

      class Remove
        include OwnerGuard

        def initialize(uow:, attachments:, storage:, audit:, clock:, guards: {})
          @uow = uow
          @attachments = attachments
          @storage = storage
          @audit = audit
          @clock = clock
          @guards = guards
        end

        def call(actor, attachment_id)
          @uow.run(actor) do |tx, current|
            row = @attachments.find(tx, Domain::Identifier.parse(attachment_id)) || raise(Domain::NotFound, "anexo")
            Authorizer.authorize!(current, PERMISSIONS.fetch(row["owner_type"]).last)
            guard!(tx, row["owner_type"], row["owner_id"])
            now = @clock.now
            if row["retain_until"] && row["retain_until"] > now
              raise Domain::Conflict.new("anexo em período de retenção até #{row["retain_until"].utc.iso8601}",
                                         code: "retained")
            end

            @attachments.soft_delete(tx, row["id"], now)
            @audit.record(tx, current, "attachment.removed", row["owner_type"], row["owner_id"], "attachment_id" => row["id"])
            tx.after_commit { @storage.delete(row["storage_key"]) }
            true
          end
        end
      end
    end
  end
end
