# frozen_string_literal: true

module Locentra
  module Application
    module Finance
      # Conta do provedor de pagamentos da organização. A chave de API é cifrada; o token dos
      # webhooks recebidos é exibido uma única vez e armazenado somente como SHA-256.
      class ConfigureProviderAccount
        KEY_PREFIXES = { "sandbox" => "$aact_hmlg_", "production" => "$aact_prod_" }.freeze

        # `enabled`: provedores habilitados no processo (PAYMENT_PROVIDERS).
        def initialize(uow:, accounts:, limits:, box:, audit:, clock:, ids:, enabled: F::ONLINE_PROVIDERS)
          @uow = uow
          @accounts = accounts
          @limits = limits
          @box = box
          @audit = audit
          @clock = clock
          @ids = ids
          @enabled = enabled
        end

        def call(actor, provider:, name:, api_key: nil, environment: "sandbox")
          raise Domain::ValidationError.field("provedor", "use simulator ou asaas") unless F::ONLINE_PROVIDERS.include?(provider)
          raise Domain::ValidationError.field("provedor", "provedor não habilitado neste ambiente") unless @enabled.include?(provider)
          raise Domain::ValidationError.field("ambiente", "use sandbox ou production") unless KEY_PREFIXES.key?(environment)

          key = provider == "asaas" ? api_key!(api_key, environment) : nil
          @uow.run(actor, "integrations.manage") do |tx, current|
            @limits.feature!(tx, "pagamentos_online")
            now = @clock.now
            previous = @accounts.active(tx)
            @accounts.deactivate(tx, previous["id"], now) if previous
            token = "whk_#{@ids.token(32)}"
            row = { "id" => @ids.uuid, "provider" => provider, "name" => Domain::Organizations::Text.required(name, "nome", min: 2, max: 80),
                    "environment" => provider == "asaas" ? environment : "sandbox", "api_key_ciphertext" => key && @box.encrypt(key),
                    "api_key_hint" => key && "…#{key[-4, 4]}", "webhook_token_digest" => TokenCheck.digest(token),
                    "webhook_token_hint" => "…#{token[-4, 4]}", "created_by" => current.user_id, "created_at" => now }
            @accounts.insert(tx, row)
            @audit.record(tx, current, "payment_account.configured", "payment_provider_account", row["id"],
                          "provider" => provider, "environment" => row["environment"], "replaced" => previous&.fetch("id"))
            row.slice("id", "provider", "name", "environment").merge("webhook_token" => token, "webhook_path" => "/webhooks/pagamentos/#{row["id"]}")
          end
        end

        private

        # O prefixo da chave identifica o ambiente (documentação do Asaas: $aact_hmlg_ no sandbox,
        # $aact_prod_ em produção).
        def api_key!(value, environment)
          key = value.to_s.strip
          raise Domain::ValidationError.field("chave_api", "obrigatória para o Asaas") if key.empty?
          raise Domain::ValidationError.field("chave_api", "chave muito longa") if key.length > 300
          unless key.start_with?(KEY_PREFIXES[environment])
            raise Domain::ValidationError.field("chave_api",
                                                "a chave não corresponde ao ambiente #{environment}")
          end

          key
        end
      end

      class DeactivateProviderAccount
        def initialize(uow:, accounts:, audit:, clock:)
          @uow = uow
          @accounts = accounts
          @audit = audit
          @clock = clock
        end

        def call(actor, account_id)
          @uow.run(actor, "integrations.manage") do |tx, current|
            id = Domain::Identifier.parse(account_id, "conta")
            raise Domain::NotFound, "conta do provedor" unless @accounts.deactivate(tx, id, @clock.now) == 1

            @audit.record(tx, current, "payment_account.deactivated", "payment_provider_account", id)
            true
          end
        end
      end

      # Decisão registrada para um alerta financeiro (o alerta não altera reservas nem pagamentos).
      class ResolveAlert
        RESOLUTIONS = F::ALERT_RESOLUTIONS

        def initialize(uow:, alerts:, audit:, clock:)
          @uow = uow
          @alerts = alerts
          @audit = audit
          @clock = clock
        end

        def call(actor, alert_id, resolution:, notes: nil)
          raise Domain::ValidationError.field("decisao", "use reembolso, nova reserva ou sem ação") unless RESOLUTIONS.key?(resolution)

          @uow.run(actor, "finance.write") do |tx, current|
            alert = @alerts.lock(tx, Domain::Identifier.parse(alert_id, "alerta")) || raise(Domain::NotFound, "alerta")
            raise Domain::Conflict.new("Alerta já resolvido", code: "alert_resolved") unless alert["status"] == "open"

            text = Domain::Organizations::Text.optional(notes, max: 500)
            @alerts.resolve(tx, alert["id"], resolution, text, current.audit_actor_id, @clock.now)
            @audit.record(tx, current, "finance_alert.resolved", "finance_alert", alert["id"], "resolution" => resolution, "notes" => text)
            true
          end
        end
      end

      # Fatura comercial: demonstrativo numerado e imutável das cobranças da reserva, com valores
      # pagos e saldo no momento da emissão. Não é documento fiscal (NFS-e fora do escopo).
      class IssueInvoice
        def initialize(uow:, reservations:, receivables:, organizations:, invoices:, audit:, clock:, ids:)
          @uow = uow
          @reservations = reservations
          @receivables = receivables
          @organizations = organizations
          @invoices = invoices
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, reservation_id, notes: nil)
          @uow.run(actor, "finance.write") do |tx, current|
            reservation = @reservations.find(tx, Domain::Identifier.parse(reservation_id, "reserva")) || raise(Domain::NotFound, "reserva")
            rows = @receivables.for_reservation(tx, reservation.id).reject { |row| row[:balance].cancelled? }
            raise Domain::ValidationError.field("cobrancas", "a reserva não tem cobranças ativas para faturar") if rows.empty?

            row = invoice_row(tx, current, reservation, rows, notes)
            @invoices.insert(tx, row)
            @audit.record(tx, current, "invoice.issued", "invoice", row["id"], "number" => row["number"], "total_cents" => row["total_cents"])
            row
          end
        end

        private

        def invoice_row(tx, actor, reservation, rows, notes)
          lines = rows.map do |row|
            r = row[:receivable]
            { "receivable_id" => r.id, "kind" => r.kind, "description" => r.description, "due_on" => r.due_on.iso8601,
              "amount_cents" => r.amount.cents, "settled_cents" => row[:balance].settled.cents, "outstanding_cents" => row[:balance].outstanding.cents }
          end
          { "id" => @ids.uuid, "number" => @organizations.next_code(tx, "invoice", "FAT"), "reservation_id" => reservation.id,
            "customer_id" => reservation.customer_id, "total_cents" => lines.sum { |l| l["amount_cents"] },
            "settled_cents" => lines.sum { |l| l["settled_cents"] }, "outstanding_cents" => lines.sum { |l| l["outstanding_cents"] },
            "lines" => lines, "notes" => Domain::Organizations::Text.optional(notes, max: 1000),
            "created_by" => actor.audit_actor_id, "issued_at" => @clock.now }
        end
      end
    end
  end
end
