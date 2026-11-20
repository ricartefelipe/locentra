# frozen_string_literal: true

require "openssl"

module Locentra
  module Application
    module Finance
      F = Domain::Finance

      # Porta de provedores de pagamento. Adaptadores (simulador, Asaas) implementam:
      #   create_charge(account, ChargeRequest) -> ProviderCharge
      #   find_by_external_reference(account, referencia) -> [ProviderCharge]
      #   list_charges(account, since:) -> ChargeListing (cobranças criadas a partir de `since`, ou antes)
      #   refunds(account, provider_payment_id) -> [ProviderRefund]
      #   refund(account, provider_payment_id, amount:, description:) -> ProviderRefund
      #   parse_webhook(texto_json) -> ProviderEvent
      # Toda chamada ocorre fora de transação de banco. Situação de reembolso normalizada pelo
      # adaptador: "done" (concluído), "pending" (em andamento ou aguardando autorização) ou "cancelled".
      class ProviderError < StandardError; end
      # Resultado desconhecido: a requisição pode ter sido processada (tempo esgotado após o envio).
      class ProviderTimeout < ProviderError; end
      # Recusa definitiva do provedor (dados inválidos, credencial recusada).
      class ProviderRejected < ProviderError; end
      # Requisição não enviada (conexão recusada, limite de taxa): pode ser repetida com segurança.
      class ProviderUnavailable < ProviderError; end
      # Webhook recebido sem token válido para a conta.
      class WebhookUnauthorized < StandardError; end

      CustomerRef = Data.define(:id, :name, :document, :email)
      ChargeRequest = Data.define(:external_reference, :amount, :payment_method, :due_on, :description, :customer, :scenario)
      ProviderCharge = Data.define(:provider_payment_id, :external_reference, :status, :amount, :invoice_url)
      ProviderRefund = Data.define(:reference, :description, :amount, :status) do
        def done? = status == "done"
        def cancelled? = status == "cancelled"
      end
      # `complete` falso: o provedor tem mais cobranças do que as devolvidas (limite de páginas); a
      # ausência de uma cobrança na listagem não prova nada.
      ChargeListing = Data.define(:charges, :complete)
      # Consulta pela referência externa de um pagamento: instante em que começou e tentativa de envio
      # observada antes dela (a conclusão só vale se nenhuma tentativa nova começou depois).
      Lookup = Data.define(:charges, :at, :attempt) do
        # Consulta ao provedor, fora de transação. O ator leva a correlação para o log da chamada.
        def self.perform(providers, account, payment, clock, actor: nil)
          at = clock.now
          charges = providers.for(account["provider"], actor: actor).find_by_external_reference(account, payment.external_reference)
          new(charges: charges, at: at, attempt: payment.submission_attempts)
        end
      end
      # action: "confirm" (pago), "cancel" (removido), "ignore" (informativo).
      ProviderEvent = Data.define(:event_id, :event_type, :action, :provider_payment_id, :external_reference, :status, :amount)

      # Adaptadores por nome de provedor. Com `calls` (ExternalCalls) e o ator da operação, o adaptador
      # devolvido registra cada chamada de rede com a organização e a correlação do ator. `calls` é
      # posicional para que o mapa possa ser passado sem chaves (`Providers.new("simulator" => a)`).
      class Providers
        def initialize(map, calls = nil)
          @map = map.freeze
          @calls = calls
        end

        def for(name, actor: nil)
          adapter = @map.fetch(name) { raise Domain::ValidationError.field("provedor", "provedor de pagamento não configurado: #{name}") }
          return adapter unless @calls && actor

          TrackedProvider.new(adapter, name: name, actor: actor, calls: @calls)
        end
      end

      # Adaptador de provedor com registro das chamadas de rede (a interpretação de webhooks é local
      # e não é registrada). Desfechos: ok, timeout (resultado desconhecido), rejected, unavailable e
      # error (resposta inesperada).
      class TrackedProvider
        ERRORS = { ProviderTimeout => "timeout", ProviderRejected => "rejected", ProviderUnavailable => "unavailable" }.freeze

        def initialize(adapter, name:, actor:, calls:)
          @adapter = adapter
          @name = name
          @actor = actor
          @calls = calls
        end

        def create_charge(account, request)
          track("create_charge", reference: request.external_reference) { @adapter.create_charge(account, request) }
        end

        def find_by_external_reference(account, reference)
          track("find_by_external_reference", reference: reference) { @adapter.find_by_external_reference(account, reference) }
        end

        def list_charges(account, since:)
          track("list_charges") { @adapter.list_charges(account, since: since) }
        end

        def refunds(account, provider_payment_id)
          track("refunds", provider_payment_id: provider_payment_id) { @adapter.refunds(account, provider_payment_id) }
        end

        def refund(account, provider_payment_id, amount:, description:)
          track("refund", provider_payment_id: provider_payment_id) do
            @adapter.refund(account, provider_payment_id, amount: amount, description: description)
          end
        end

        def parse_webhook(body) = @adapter.parse_webhook(body)

        private

        def track(operation, **details, &)
          @calls.track(service: @name, operation: operation, organization_id: @actor.organization_id, correlation_id: @actor.request_id,
                       errors: ERRORS, details: details, &)
        end
      end

      # Execução com transação própria ou composta (o chamador já abriu a transação e autorizou o ator).
      module Composable
        private

        def within(actor, permission, tx, &)
          return yield(tx, actor) if tx

          @uow.run(actor, permission, &)
        end
      end

      # Diário contábil: cada operação gera uma transação contábil balanceada, somente inserção.
      class Ledger
        def initialize(entries:, ids:, clock:)
          @entries = entries
          @ids = ids
          @clock = clock
        end

        def post(tx, posting, source_type:, source_id:)
          transaction_id = @ids.uuid
          rows = posting.lines.each_with_index.map do |line, index|
            { "id" => @ids.uuid, "transaction_id" => transaction_id, "position" => index + 1, "account" => line.account,
              "debit_cents" => line.debit.cents, "credit_cents" => line.credit.cents, "source_type" => source_type,
              "source_id" => source_id, "memo" => posting.memo, "occurred_at" => @clock.now }
          end
          @entries.insert(tx, rows)
          transaction_id
        end
      end

      # Alertas que exigem decisão, deduplicados por chave estável.
      class AlertBook
        def initialize(alerts:, ids:, clock:)
          @alerts = alerts
          @ids = ids
          @clock = clock
        end

        def raise_alert(tx, kind:, message:, dedupe_key:, reservation_id: nil, payment_id: nil)
          @alerts.insert(tx, "id" => @ids.uuid, "kind" => kind, "message" => message, "dedupe_key" => dedupe_key,
                             "reservation_id" => reservation_id, "payment_id" => payment_id, "created_at" => @clock.now)
        end
      end

      # Efeitos de um pagamento confirmado: diário, movimento de caução, revisão, auditoria e evento.
      # A reserva nunca é alterada: pagamento após expiração ou cancelamento gera revisão e alerta.
      class Settlement
        def initialize(payments:, deposits:, reservations:, ledger:, alert_book:, audit:, events:, clock:, ids:)
          @payments = payments
          @deposits = deposits
          @reservations = reservations
          @ledger = ledger
          @alert_book = alert_book
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
        end

        # A reserva é lida com FOR SHARE: um cancelamento ou expiração em andamento termina antes da
        # decisão (e é visto por ela). Bloqueio temporário vencido e ainda não varrido conta como
        # expirado: o dinheiro chegou depois do prazo, mesmo que o sweeper ainda não tenha passado.
        def findings(tx, reservation_id, expected: nil, received: nil)
          reservation = reservation_id && @reservations.lock_shared(tx, reservation_id)
          [F::Review.for_reservation(effective_status(reservation)), expected && F::Review.amount_mismatch(expected, received)].compact
        end

        # Confirma um pagamento já bloqueado (FOR UPDATE) pelo chamador. `extra`: achados adicionais
        # ([tipo de alerta, motivo]) que também exigem revisão.
        def confirm(tx, actor, payment, from:, received: nil, extra: [])
          return payment if payment.confirmed?

          found = findings(tx, payment.reservation_id, expected: payment.amount, received: received) + extra
          confirmed = payment.confirm(@clock.now, review_reason: F::Review.reason_text(found))
          @payments.update(tx, confirmed, from: from, now: @clock.now)
          effects(tx, actor, confirmed, found)
          confirmed
        end

        def effective_status(reservation)
          return nil unless reservation

          reservation.hold_expired?(@clock.now) ? "expired" : reservation.status
        end

        def effects(tx, actor, payment, found)
          @ledger.post(tx, F::Postings.payment_confirmed(payment), source_type: "payment", source_id: payment.id)
          if payment.purpose == "deposit"
            @deposits.insert_entry(tx, "id" => @ids.uuid, "deposit_id" => payment.deposit_id, "kind" => "receive", "amount_cents" => payment.amount.cents,
                                       "payment_id" => payment.id, "method" => payment.payment_method, "created_by" => actor&.audit_actor_id,
                                       "created_at" => @clock.now)
          end
          found.each do |kind, message|
            @alert_book.raise_alert(tx, kind: kind, message: message, dedupe_key: "#{kind}:#{payment.id}", reservation_id: payment.reservation_id,
                                        payment_id: payment.id)
          end
          @audit.record(tx, actor, "payment.confirmed", "payment", payment.id,
                        "amount_cents" => payment.amount.cents, "provider" => payment.provider, "purpose" => payment.purpose,
                        "requires_review" => payment.requires_review)
          @events.publish(tx, "payment.confirmed", "payment", payment.id,
                          "reservation_id" => payment.reservation_id, "amount_cents" => payment.amount.cents, "requires_review" => payment.requires_review)
        end
      end

      # Aplica a situação de uma cobrança encontrada no provedor a um pagamento local bloqueado.
      class RemoteSync
        def initialize(payments:, settlement:, clock:)
          @payments = payments
          @settlement = settlement
          @clock = clock
        end

        def apply(tx, actor, payment, charge)
          adopted = payment.adopt(charge.provider_payment_id, charge.invoice_url)
          case charge.status
          when "confirmed", "refunded", "disputed"
            @settlement.confirm(tx, actor, adopted, from: payment.status, received: charge.amount)
          when "cancelled"
            save(tx, adopted.cancel("cobrança removida no provedor"), payment.status)
          else
            save(tx, payment.status == "pending" ? adopted : adopted.transition("pending"), payment.status)
          end
        end

        private

        def save(tx, payment, from)
          @payments.update(tx, payment, from: from, now: @clock.now)
          payment
        end
      end

      # Comparação de tokens em tempo constante (sobre os resumos SHA-256).
      module TokenCheck
        DUMMY = "0" * 64

        module_function

        def digest(token) = OpenSSL::Digest::SHA256.hexdigest(token.to_s)

        def match?(expected_digest, token)
          expected = expected_digest.to_s.length == 64 ? expected_digest.to_s : DUMMY
          OpenSSL.fixed_length_secure_compare(expected, digest(token)) && expected != DUMMY
        end
      end
    end
  end
end
