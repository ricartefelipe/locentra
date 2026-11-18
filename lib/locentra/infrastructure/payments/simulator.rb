# frozen_string_literal: true

require "json"

module Locentra
  module Infrastructure
    module Payments
      # Provedor local determinístico, persistido em payment_simulator_charges (o "lado do provedor").
      # O resultado depende somente do cenário escolhido na cobrança:
      # - success: registra a cobrança pendente;
      # - fail: recusa sem registrar;
      # - timeout_after_success: registra a cobrança e lança tempo esgotado (o chamador não sabe o resultado).
      # Como num provedor real, não há unicidade por referência externa: um reenvio às cegas criaria uma
      # segunda cobrança. Eventos usam o formato do Asaas e identificadores estáveis.
      class Simulator
        FN = Application::Finance
        COLUMNS = "id, external_reference, billing_type, value_cents, due_date, status, refunds, created_at"

        def initialize(transactor:, clock:, ids:)
          @transactor = transactor
          @clock = clock
          @ids = ids
        end

        def create_charge(account, request)
          raise FN::ProviderRejected, "Cobrança recusada pelo simulador (cenário de recusa)" if request.scenario == "fail"

          now = @clock.now
          row = within(account) do |tx|
            tx.query_one(<<~SQL, ["sim_#{@ids.uuid.delete("-")}", tx.tenant_id!, account["id"], request.external_reference, request.customer.id, AsaasFormat::BILLING_TYPES.fetch(request.payment_method), request.amount.cents, request.due_on, now])
              INSERT INTO payment_simulator_charges (id, organization_id, account_id, external_reference, customer_reference, billing_type, value_cents,
                                                     due_date, status, created_at, updated_at)
              VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'PENDING', $9, $9)
              RETURNING #{COLUMNS}
            SQL
          end
          raise FN::ProviderTimeout, "Tempo esgotado após o simulador registrar a cobrança" if request.scenario == "timeout_after_success"

          to_charge(row)
        end

        def find_by_external_reference(account, reference)
          rows = within(account) do |tx|
            tx.query("SELECT #{COLUMNS} FROM payment_simulator_charges WHERE organization_id = $1 AND account_id = $2 AND external_reference = $3 " \
                     "ORDER BY created_at, id", [tx.tenant_id!, account["id"], reference.to_s])
          end
          rows.map { |row| to_charge(row) }
        end

        def list_charges(account, since:)
          rows = within(account) do |tx|
            tx.query("SELECT #{COLUMNS} FROM payment_simulator_charges WHERE organization_id = $1 AND account_id = $2 AND created_at >= $3 " \
                     "ORDER BY created_at, id", [tx.tenant_id!, account["id"], since])
          end
          FN::ChargeListing.new(charges: rows.map { |row| to_charge(row) }, complete: true)
        end

        def refunds(account, provider_payment_id)
          row = within(account) { |tx| find(tx, account, provider_payment_id) }
          raise FN::ProviderRejected, "Cobrança inexistente no simulador" unless row

          row["refunds"].map { |r| to_refund(r) }
        end

        def refund(account, provider_payment_id, amount:, description:)
          within(account) do |tx|
            row = find(tx, account, provider_payment_id, lock: true)
            raise FN::ProviderRejected, "Cobrança inexistente no simulador" unless row
            raise FN::ProviderRejected, "Somente cobranças recebidas podem ser estornadas" unless %w[RECEIVED REFUNDED].include?(row["status"])

            refunded = row["refunds"].sum { |r| r["value_cents"] }
            raise FN::ProviderRejected, "Estorno acima do valor da cobrança" if refunded + amount.cents > row["value_cents"]

            entry = { "reference" => "simref_#{@ids.uuid.delete("-")}", "description" => description, "value_cents" => amount.cents, "status" => "DONE" }
            status = refunded + amount.cents == row["value_cents"] ? "REFUNDED" : row["status"]
            tx.execute(<<~SQL, [tx.tenant_id!, row["id"], JSON.generate(row["refunds"] + [entry]), status, @clock.now])
              UPDATE payment_simulator_charges SET refunds = $3::jsonb, status = $4, updated_at = $5 WHERE organization_id = $1 AND id = $2
            SQL
            to_refund(entry)
          end
        end

        # Marca a cobrança como recebida e devolve o evento de webhook (identificador estável: repetir a
        # simulação produz o mesmo evento, que é deduplicado na recepção).
        def settle(account, provider_payment_id)
          row = within(account) do |tx|
            found = find(tx, account, provider_payment_id, lock: true)
            raise FN::ProviderRejected, "Cobrança inexistente no simulador" unless found

            if found["status"] == "PENDING"
              tx.execute("UPDATE payment_simulator_charges SET status = 'RECEIVED', updated_at = $3 WHERE organization_id = $1 AND id = $2",
                         [tx.tenant_id!, found["id"], @clock.now])
            end
            found
          end
          event(row, "PAYMENT_RECEIVED", "RECEIVED")
        end

        def parse_webhook(text) = AsaasFormat.parse_event(text)

        private

        def within(account, &) = @transactor.call(tenant_id: account.fetch("organization_id"), &)

        def find(tx, account, provider_payment_id, lock: false)
          tx.query_one("SELECT #{COLUMNS} FROM payment_simulator_charges WHERE organization_id = $1 AND account_id = $2 AND id = $3 " \
                       "#{"FOR UPDATE" if lock}", [tx.tenant_id!, account["id"], provider_payment_id.to_s])
        end

        def event(row, type, status)
          JSON.generate("id" => "evt_sim_#{row["id"].delete_prefix("sim_")}_#{type.downcase}", "event" => type,
                        "dateCreated" => @clock.now.strftime("%Y-%m-%d %H:%M:%S"),
                        "payment" => { "id" => row["id"], "status" => status, "value" => AsaasFormat.decimal(Domain::Money.new(row["value_cents"])),
                                       "externalReference" => row["external_reference"], "billingType" => row["billing_type"] })
        end

        def to_charge(row)
          FN::ProviderCharge.new(provider_payment_id: row["id"], external_reference: row["external_reference"],
                                 status: AsaasFormat.status(row["status"]), amount: Domain::Money.new(row["value_cents"]), invoice_url: nil)
        end

        def to_refund(entry)
          FN::ProviderRefund.new(reference: entry["reference"], description: entry["description"], amount: Domain::Money.new(entry["value_cents"]),
                                 status: AsaasFormat.refund_status(entry["status"]))
        end
      end
    end
  end
end
