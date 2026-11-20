# frozen_string_literal: true

require_relative "finance_handlers"

module Locentra
  module Interfaces
    module Worker
      # Erro que encerra a tarefa sem novas tentativas (dados inválidos, recurso inexistente).
      class PermanentFailure < StandardError; end

      # Tabela explícita tipo de tarefa → handler. Cada handler recebe a tarefa reivindicada e abre
      # transações curtas com o tenant da própria tarefa. Chamadas de rede ocorrem fora de transação.
      class Handlers
        # Retenção de tarefas concluídas (platform.housekeeping) e tamanho de cada lote removido.
        JOB_RETENTION = 14 * 86_400
        PURGE_BATCH = 5_000

        def initialize(system, mailer:, templates:)
          @system = system
          @mailer = mailer
          @templates = templates
          @map = {
            "events.dispatch" => method(:dispatch_event),
            "webhooks.deliver" => method(:deliver_webhook),
            "email.confirmation" => method(:email_confirmation),
            "email.password_reset" => method(:email_password_reset),
            "email.invitation" => method(:email_invitation),
            "email.portal_invitation" => method(:email_portal_invitation),
            "email.send" => method(:email_send),
            "platform.fanout" => method(:platform_fanout),
            "platform.housekeeping" => method(:platform_housekeeping),
            "organization.tick" => method(:organization_tick)
          }
          @finance = FinanceHandlers.new(system)
          @map.merge!(@finance.map)
        end

        def register(kind, callable)
          @map[kind] = callable
        end

        def kinds = @map.keys

        def call(job)
          handler = @map[job.kind] || raise(PermanentFailure, "tipo de tarefa desconhecido: #{job.kind}")
          handler.call(job)
        end

        private

        def uc(name) = @system.use_cases[name]
        def tenant(job, &) = @system.transactor.call(tenant_id: job.organization_id, &)

        def dispatch_event(job)
          tenant(job) { |tx| @system.services[:dispatch_event].call(tx, job.payload.fetch("event_id")) }
        end

        def deliver_webhook(job)
          @system.services[:deliver_webhook].call(job.organization_id, job.payload.fetch("delivery_id"), correlation_id: job.correlation_id)
        end

        def email_confirmation(job)
          user, token = @system.transactor.call do |tx|
            found = @system.repos[:users].find(tx, job.payload.fetch("user_id")) || raise(PermanentFailure, "usuário inexistente")
            next [found, nil] if found["email_confirmed_at"]

            [found, @system.services[:tokens].issue(tx, found["id"], "email_confirmation", 48 * 3600)]
          end
          return :already_confirmed unless token

          send_template("email_confirmation", user["email"], "name" => user["name"], "link" => link("/confirmar-email", token))
        end

        def email_password_reset(job)
          user, token = @system.transactor.call do |tx|
            found = @system.repos[:users].find(tx, job.payload.fetch("user_id")) || raise(PermanentFailure, "usuário inexistente")
            [found, @system.services[:tokens].issue(tx, found["id"], "password_reset", 3600)]
          end
          send_template("password_reset", user["email"], "name" => user["name"], "link" => link("/redefinir-senha", token))
        end

        # O token do convite é emitido aqui: o segredo nunca fica gravado na fila.
        # Convite já aceito, revogado ou expirado não gera e-mail (a tarefa conclui sem envio).
        def email_invitation(job)
          invitation, org, token = tenant(job) do |tx|
            row = tx.query_one(<<~SQL, [tx.tenant_id!, job.payload.fetch("invitation_id"), @system.clock.now])
              SELECT id, email, role FROM invitations
               WHERE organization_id = $1 AND id = $2 AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > $3 FOR UPDATE
            SQL
            next nil unless row

            secret = "#{tx.tenant_id!}.#{@system.ids.token(32)}"
            tx.execute("UPDATE invitations SET token_digest = $2 WHERE organization_id = $3 AND id = $1",
                       [row["id"], Application::Identity::Tokens.digest(secret), tx.tenant_id!])
            [row, @system.repos[:organizations].find(tx, tx.tenant_id!), secret]
          end
          return :invitation_closed unless invitation

          send_template("invitation", invitation["email"], "organization" => org.name,
                                                           "role" => Domain::Identity.role_label(invitation["role"]), "link" => link("/convites", token))
        end

        # Convite do portal do cliente: como no convite da equipe, o token é emitido no envio e a fila
        # guarda somente o identificador. Convite aceito, cancelado ou vencido não gera e-mail.
        def email_portal_invitation(job)
          delivery = tenant(job) do |tx|
            portal = @system.repos[:portal]
            invitation = portal.lock_deliverable_invitation(tx, job.payload.fetch("invitation_id"), @system.clock.now)
            next nil unless invitation

            secret = "#{tx.tenant_id!}.#{@system.ids.token(32)}"
            portal.assign_token(tx, invitation.id, Application::Identity::Tokens.digest(secret))
            [invitation, @system.repos[:organizations].find(tx, tx.tenant_id!), @system.repos[:customers].find(tx, invitation.customer_id), secret]
          end
          return :invitation_closed unless delivery

          invitation, org, customer, token = delivery
          send_template("portal_invitation", invitation.email,
                        "organization" => org.name, "customer" => customer.name, "link" => link("/portal/convite", token))
        end

        def email_send(job)
          vars = job.payload.fetch("variables", {}).dup
          if job.organization_id
            zone = tenant(job) { |tx| @system.repos[:organizations].find(tx, tx.tenant_id!).time_zone }
            %w[starts_at ends_at valid_until].each do |key|
              vars["#{key}_local"] = zone.format_local(Time.iso8601(vars[key])) if vars[key]
            end
          end
          send_template(job.payload.fetch("template"), job.payload.fetch("to"), vars)
        end

        # Agendamentos por organização com chave única por janela de tempo (sem duplicar entre workers).
        def platform_fanout(job)
          bucket = job.payload.fetch("bucket")
          orgs = @system.transactor.call { |tx| tx.query("SELECT id FROM organizations WHERE status = 'active' ORDER BY id").map { |r| r["id"] } }
          orgs.each do |org_id|
            @system.transactor.call(tenant_id: org_id) do |tx|
              @system.queue.enqueue(tx, "organization.tick", { "bucket" => bucket }, unique_key: "org-tick:#{org_id}:#{bucket}", priority: 30)
            end
          end
          orgs.size
        end

        # Limpeza periódica. Tarefas concluídas (succeeded, cancelled) saem depois de JOB_RETENTION, em
        # lotes, com as tentativas; tarefas mortas ficam até serem reprocessadas ou tratadas. Eventos da
        # outbox, entregas de webhook e webhooks recebidos são histórico do negócio e não são removidos.
        def platform_housekeeping(_job)
          now = @system.clock.now
          purged = @system.transactor.call do |tx|
            @system.repos[:reports].refresh_queue_stats(tx, now)
            tx.execute("DELETE FROM rate_limits WHERE window_start < $1", [now - 86_400])
            tx.execute("DELETE FROM sessions WHERE absolute_expires_at < $1", [now - (30 * 86_400)])
            tx.execute("DELETE FROM user_tokens WHERE expires_at < $1", [now - (30 * 86_400)])
            tx.execute(<<~SQL, [now - JOB_RETENTION, PURGE_BATCH])
              DELETE FROM jobs WHERE id IN (
                SELECT id FROM jobs WHERE status IN ('succeeded', 'cancelled') AND finished_at < $1 ORDER BY finished_at LIMIT $2)
            SQL
          end
          { "jobs_purged" => purged }
        end

        # Rotina por organização: expira bloqueios e orçamentos vencidos, detecta atrasos e limpa
        # chaves de idempotência vencidas. Cada etapa é idempotente.
        def organization_tick(job)
          actor = Application::Actor.system(organization_id: job.organization_id, request_id: job.correlation_id)
          expired = uc(:expire_holds).call(actor)
          expired_quotes = uc(:expire_quotes).call(actor)
          overdue = @system.use_cases.names.include?(:detect_overdue) ? uc(:detect_overdue).call(actor) : []
          tenant(job) { |tx| @system.repos[:idempotency].purge(tx, @system.clock.now) }
          reconciliation = @finance.schedule_reconciliation(job)
          { "expired" => expired.size, "expired_quotes" => expired_quotes.size, "overdue" => Array(overdue).size,
            "reconciliation_scheduled" => !reconciliation.nil? }
        end

        def send_template(template, to, vars)
          subject, body = @templates.render(template, vars)
          @mailer.deliver(to: to, subject: subject, text: body)
        rescue ArgumentError, Errno::ENOENT => e
          raise PermanentFailure, "e-mail inválido: #{e.message}"
        end

        def link(path, token)
          "#{@system.config.base_url}#{path}?token=#{URI.encode_www_form_component(token)}"
        end
      end
    end
  end
end
