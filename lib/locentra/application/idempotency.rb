# frozen_string_literal: true

require "digest"
require "json"

module Locentra
  module Application
    # Execução idempotente de operações com chave fornecida pelo cliente.
    #
    # Na mesma transação da operação: reserva a chave (INSERT ... ON CONFLICT DO NOTHING), executa e
    # grava o resultado. Uma requisição concorrente equivalente aguarda o término da primeira no
    # índice único e então devolve o resultado persistido. Chave reutilizada com conteúdo diferente
    # gera conflito. Se a operação falhar, nada é gravado e a chave pode ser usada novamente.
    class Idempotency
      KEY = /\A[A-Za-z0-9_.:-]{8,255}\z/
      TTL = 24 * 3600

      Result = Data.define(:status, :body, :replayed)

      def initialize(uow:, repository:, clock:, ids:)
        @uow = uow
        @repository = repository
        @clock = clock
        @ids = ids
      end

      def self.fingerprint(verb, path, payload)
        Digest::SHA256.hexdigest("#{verb} #{path}\n#{JSON.generate(canonical(payload))}")
      end

      def self.canonical(value)
        case value
        when Hash then value.keys.map(&:to_s).sort.to_h { |k| [k, canonical(value[k] || value[k.to_sym])] }
        when Array then value.map { |v| canonical(v) }
        else value
        end
      end

      # O bloco recebe (tx, ator revalidado) e devolve [status, corpo]. Só respostas 2xx são gravadas.
      def call(actor, permission:, scope:, key:, fingerprint:)
        raise Domain::ValidationError.field("Idempotency-Key", "obrigatória (8 a 255 caracteres seguros)") unless key.to_s.match?(KEY)

        full_scope = "#{actor.kind}:#{actor.audit_actor_id}:#{scope}"
        @uow.run(actor, permission) do |tx, current|
          now = @clock.now
          if @repository.claim(tx, "id" => @ids.uuid, "scope" => full_scope, "key" => key, "fingerprint" => fingerprint,
                                   "created_at" => now, "expires_at" => now + TTL)
            status, body = yield(tx, current)
            @repository.store(tx, full_scope, key, status, body)
            Result.new(status: status, body: body, replayed: false)
          else
            replay(tx, full_scope, key, fingerprint)
          end
        end
      end

      private

      def replay(tx, scope, key, fingerprint)
        stored = @repository.find(tx, scope, key)
        raise Domain::Conflict.new("chave de idempotência em uso", code: "idempotency_in_progress") unless stored
        unless stored["fingerprint"] == fingerprint
          raise Domain::Conflict.new("chave de idempotência reutilizada com conteúdo diferente", code: "idempotency_key_reused")
        end

        Result.new(status: stored["response_status"], body: stored["response_body"], replayed: true)
      end
    end
  end
end
