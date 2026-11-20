# frozen_string_literal: true

module Locentra
  module Application
    # Tarefas da fila que esgotaram as tentativas (`dead`) e o reprocessamento autorizado.
    #
    # As duas operações exigem `jobs.manage`: a mensagem de erro de uma tarefa pode revelar detalhes
    # de integrações. O reprocessamento devolve a tarefa a `pending` com as tentativas zeradas e é
    # auditado na mesma transação; o histórico em `job_attempts` é preservado (a numeração continua e
    # tentativas abandonadas são encerradas). Tarefas de outra organização ou sem organização não são
    # visíveis (filtro explícito e RLS).
    module Jobs
      STATUSES = {
        "pending" => "Pendente", "running" => "Em execução", "succeeded" => "Concluída",
        "dead" => "Morta (tentativas esgotadas)", "cancelled" => "Cancelada"
      }.freeze

      DEFAULT_LIMIT = 50
      AUDIT_ERROR_LENGTH = 300

      # Remove da mensagem de erro credenciais de integração, credenciais embutidas em URLs,
      # parâmetros de consulta e pares chave=valor sensíveis antes de exibi-la ou auditá-la.
      #
      # Chaves sensíveis valem isoladas ou como parte de nomes compostos (`access_token`,
      # `client_secret`, `x-api-key`), em `chave=valor`, `chave: valor` ou JSON (`"chave":"valor"`).
      # O valor inclui o esquema de autenticação (`Authorization: Bearer ...`) e, entre aspas, vai até
      # a aspa de fechamento.
      module ErrorText
        CREDENTIAL_TOKEN = /lcn_[0-9a-f]{32}_[A-Za-z0-9_-]{43}/
        PROVIDER_KEY = %r{\$aact_[A-Za-z0-9_+/=:$-]+}
        URL_USERINFO = %r{(\b[a-z][a-z0-9+.-]*://)[^/\s@]+@}i
        URL_QUERY = %r{(\bhttps?://[^\s?#]+)\?[^\s#]*}i
        SENSITIVE_KEY = /(?<![a-z0-9])(?:[a-z0-9]+[_-])*(?:pass(?:word|wd)?|senha|token|secret|segredo|api[_-]?key|access[_-]?key|
                         private[_-]?key|authorization)(?:[_-][a-z0-9]+)*/ix
        SENSITIVE_PAIR = /(#{SENSITIVE_KEY})(["']?\s*[=:]\s*["']?)(?:(?:bearer|basic|digest|token)\s+)?(?:(?<=")[^"]*|(?<=')[^']*|\S+)/i

        module_function

        def redact(text)
          return nil if text.nil?

          text.to_s.gsub(CREDENTIAL_TOKEN, "[credencial]")
              .gsub(PROVIDER_KEY, "[credencial]")
              .gsub(URL_USERINFO, '\1[credenciais]@')
              .gsub(URL_QUERY, '\1?[parâmetros omitidos]')
              .gsub(SENSITIVE_PAIR, '\1\2[omitido]')
        end
      end

      class ListFailures
        def initialize(uow:, queue:)
          @uow = uow
          @queue = queue
        end

        def call(actor, limit: nil)
          lim, = Page.params(limit: limit, default: DEFAULT_LIMIT)
          @uow.run(actor, "jobs.manage") do |tx, _|
            @queue.failures(tx, limit: lim).map { |row| row.merge("last_error" => ErrorText.redact(row["last_error"])) }
          end
        end
      end

      class RetryJob
        def initialize(uow:, queue:, audit:)
          @uow = uow
          @queue = queue
          @audit = audit
        end

        def call(actor, job_id)
          id = Domain::Identifier.parse(job_id, "tarefa")
          @uow.run(actor, "jobs.manage") do |tx, current|
            job = @queue.lock(tx, id) || raise(Domain::NotFound, "tarefa")
            unless job["status"] == "dead"
              raise Domain::Conflict.new("somente tarefas mortas podem ser reprocessadas (situação atual: #{STATUSES.fetch(job["status"])})",
                                         code: "job_not_dead")
            end

            @queue.requeue(tx, id)
            error = ErrorText.redact(job["last_error"])&.slice(0, AUDIT_ERROR_LENGTH)
            @audit.record(tx, current, "job.retried", "job", id, "kind" => job["kind"], "attempts" => job["attempts"], "last_error" => error)
            { "id" => id, "kind" => job["kind"], "status" => "pending", "previous_attempts" => job["attempts"] }
          end
        end
      end
    end
  end
end
