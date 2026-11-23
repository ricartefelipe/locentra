# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/worker_support"
require_relative "../support/portal_support"

# Confirmação de e-mail obrigatória (ADR-031) nos casos de uso, com banco e relógio controlado: a conta
# criada pelo cadastro opera normalmente dentro da organização, não age para fora em nome dela até
# confirmar o e-mail (cada ação bloqueada é recusada antes e aceita depois da confirmação), fica somente
# leitura depois de 7 dias, reenvia a confirmação com limite e é confirmada pelo aceite de convites.
class EmailConfirmationFlowTest < DatabaseTest
  include WorkerHelpers
  include PortalHelpers

  EC = Locentra::Domain::Identity::EmailConfirmation

  def setup
    super
    @org = create_organization(confirmed: false)
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @contact = uc(:add_contact).call(@actor, @customer.id, { name: "Paula Compras", email: "paula@cliente.test" })
    @camera = create_product(@actor, sku: "CAM-EML", tracking: "serialized", pricing: { "daily_cents" => 12_000 })
    register_assets(@actor, @camera, @branch, 2)
  end

  def teardown
    @worker_system&.shutdown
    super
  end

  def rental(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))

  def quote_draft(day = 10)
    uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, period: rental(day), lines: [line(@camera, 1)],
                                     valid_until: t("2026-03-08T12:00:00Z") })
  end

  def booking(day = 10) = reserve(@actor, @customer, @branch, rental(day), [line(@camera, 1)], mode: "confirm")

  def refusals = @system.metrics.counter_value("domain_conflicts_total", code: "email_unconfirmed").to_i

  # Tarefas de confirmação, com ou sem organização (o reenvio não tem tenant), vistas pelo papel do worker.
  def confirmation_jobs
    PG.connect(TestDatabase.worker_url).then do |conn|
      conn.exec("SELECT correlation_id FROM jobs WHERE kind = 'email.confirmation' ORDER BY created_at").column_values(0)
    ensure
      conn&.close
    end
  end

  def refused(reason = :outbound, &)
    error = assert_raises(D::EmailUnconfirmed, &)

    assert_equal reason, error.reason
    error
  end

  # Ações para fora em nome da organização: cada uma recusada antes da confirmação, sem efeito, e aceita depois.
  OUTBOUND = {
    "members.invite" => ->(t) { t.uc(:invite_member).call(t.actor, email: "novo@alfa.test", role: "attendant") },
    "credentials.create" => ->(t) { t.uc(:create_credential).call(t.actor, name: "ERP", scopes: ["customers.read"]) },
    "webhooks.create" => ->(t) { t.uc(:create_webhook).call(t.actor, url: "http://127.0.0.1:9/hook", events: ["*"]) },
    "payments.configure" => ->(t) { t.uc(:configure_payment_account).call(t.actor, provider: "simulator", name: "Simulador") },
    "quotes.send" => ->(t) { t.uc(:send_quote).call(t.actor, t.quote_draft.id) },
    "contracts.issue" => ->(t) { t.uc(:issue_contract).call(t.actor, t.booking(12).id) },
    "portal.invite" => ->(t) { t.uc(:invite_portal_contact).call(t.actor, customer_id: t.customer.id, contact_id: t.contact.id) }
  }.freeze

  attr_reader :actor, :customer, :contact

  def test_outbound_actions_are_refused_until_the_email_is_confirmed
    OUTBOUND.each do |action, run|
      error = refused { run.call(self) }

      assert_equal "Confirme seu e-mail para #{EC::OUTBOUND_ACTIONS.fetch(action)}: abra o link enviado ao seu e-mail ou peça o reenvio " \
                   "da confirmação.", error.message
    end
    assert_equal OUTBOUND.size, refusals, "recusas contadas em domain_conflicts_total{code=email_unconfirmed}"
    nothing = owner_query(<<~SQL).first.values.map(&:to_i)
      SELECT (SELECT count(*) FROM invitations) AS a, (SELECT count(*) FROM api_credentials) AS b, (SELECT count(*) FROM webhook_endpoints) AS c,
             (SELECT count(*) FROM payment_provider_accounts) AS d, (SELECT count(*) FROM contracts) AS e,
             (SELECT count(*) FROM portal_invitations) AS f, (SELECT count(*) FROM quotes WHERE status <> 'draft') AS g
    SQL

    assert_equal [0] * 7, nothing, "nenhuma ação recusada deixa registro"
    confirm_email(@org[:user_id])

    OUTBOUND.each_value { |run| refute_nil run.call(self) }
    assert_equal OUTBOUND.size, refusals
  end

  # Reenvio e reativação de webhooks e cobrança pelo provedor: a recusa vem antes de qualquer consulta.
  def test_webhook_redelivery_resume_and_provider_charges_are_refused_before_lookup
    missing = SecureRandom.uuid
    refused { uc(:resume_webhook).call(@actor, missing) }
    refused { uc(:redeliver_webhook).call(@actor, missing) }
    refused do
      uc(:request_payment).call(@actor, { purpose: "receivable", receivable_id: missing, method: "pix", amount: D::Money.new(1_000) })
    end
    confirm_email(@org[:user_id])

    assert_raises(D::NotFound) { uc(:resume_webhook).call(@actor, missing) }
    assert_raises(D::NotFound) { uc(:redeliver_webhook).call(@actor, missing) }
    error = assert_raises(D::ValidationError) do
      uc(:request_payment).call(@actor, { purpose: "receivable", receivable_id: missing, method: "pix", amount: D::Money.new(1_000) })
    end
    assert_includes error.errors.keys, "provedor"
  end

  # Operação interna liberada sem confirmação: cadastros, catálogo, disponibilidade, reservas, orçamento como
  # rascunho, retirada, devolução, manutenção, financeiro manual e configurações.
  def test_internal_operation_is_allowed_without_confirmation
    quote = quote_draft
    revised = uc(:revise_quote).call(@actor, quote.id, { customer_id: @customer.id, branch_id: @branch.id, period: rental(11),
                                                         lines: [line(@camera, 1)], valid_until: t("2026-03-08T12:00:00Z") })

    assert_equal %w[draft 2], [revised.status, revised.current_version.to_s]
    reservation = booking
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    entries = uc(:get_pickup).call(@actor, pickup.id)[:lines].map { |row| { line_id: row["id"], tag: row["allocated_tag"] } }
    uc(:check_pickup).call(@actor, pickup.id, entries)
    uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" })
    lines = uc(:return_form).call(@actor, reservation.id)[:lines]
    uc(:register_return).call(@actor, reservation.id, entries: lines.map { |row| { pickup_line_id: row["id"], outcome: "ok", quantity: 1 } })
    asset = owner_query("SELECT id FROM assets WHERE status = 'available' LIMIT 1").first["id"]
    order = uc(:open_maintenance_order).call(@actor, description: "Revisão do sensor", asset_id: asset)
    branch = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    receivables = uc(:finance).reservation(@actor, reservation.id)[:receivables]

    refute_nil order
    refute_nil branch
    assert_equal "completed", uc(:get_reservation).call(@actor, reservation.id)[:reservation].status
    assert_operator receivables.size, :>=, 0
    assert_equal 0, refusals
  end

  def test_account_becomes_read_only_at_the_deadline_and_keeps_reading
    quote = quote_draft
    @clock.advance(EC::GRACE_PERIOD_SECONDS - 1)

    assert_equal "Cliente Novo", uc(:create_customer).call(@actor, { kind: "individual", name: "Cliente Novo", document: "39053344705" }).name
    @clock.advance(1)

    refused(:read_only) { uc(:create_customer).call(@actor, { kind: "individual", name: "Outro", document: "11144477735" }) }
    refused(:read_only) { uc(:update_customer).call(@actor, @customer.id, { name: "Renomeado" }) }
    revision = { customer_id: @customer.id, branch_id: @branch.id, period: rental, lines: [line(@camera, 1)] }
    refused(:read_only) { uc(:revise_quote).call(@actor, quote.id, revision) }
    refused(:read_only) { booking }
    refused(:read_only) { uc(:create_branch).call(@actor, name: "Filial Sul", code: "SUL") }
    refused(:read_only) { uc(:send_quote).call(@actor, quote.id) }

    assert_equal 6, refusals
    assert_reads_still_work(quote)

    confirm_email(@org[:user_id])

    assert_equal "Outro", uc(:create_customer).call(@actor, { kind: "individual", name: "Outro", document: "11144477735" }).name
  end

  def assert_reads_still_work(quote)
    assert_equal 2, uc(:list_customers).call(@actor).total
    assert_equal quote.id, uc(:get_quote).call(@actor, quote.id)[:quote].id
    assert_empty uc(:list_credentials).call(@actor)
    assert_empty uc(:list_webhooks).call(@actor)[:endpoints]
    assert_empty uc(:finance).accounts(@actor)
    assert_empty uc(:list_failed_jobs).call(@actor)
    refute_nil uc(:get_organization_settings).call(@actor)[:organization]
    assert_equal 1, uc(:list_members).call(@actor)[:members].size
  end

  def test_resend_enqueues_a_new_confirmation_with_a_limit_per_user
    assert_equal 1, confirmation_jobs.size, "e-mail do cadastro"
    @clock.advance(EC::GRACE_PERIOD_SECONDS)

    3.times { assert_equal :sent, uc(:resend_email_confirmation).call(user_id: @org[:user_id], request_id: "req-reenvio-1") }
    error = assert_raises(A::Identity::TooManyRequests) { uc(:resend_email_confirmation).call(user_id: @org[:user_id]) }

    assert_operator error.retry_after, :>, 0
    assert_equal [nil, "req-reenvio-1", "req-reenvio-1", "req-reenvio-1"], confirmation_jobs
    token = @system.transactor.call { |tx| @system.services[:tokens].issue(tx, @org[:user_id], "email_confirmation", 3600) }
    uc(:confirm_email).call(token)

    assert_equal :already_confirmed, uc(:resend_email_confirmation).call(user_id: @org[:user_id])
    assert_equal 4, confirmation_jobs.size
    assert_raises(D::NotFound) { uc(:resend_email_confirmation).call(user_id: SecureRandom.uuid) }
  end

  # O link do convite chega só ao endereço convidado: aceitar confirma a conta existente de mesmo e-mail.
  def test_accepting_a_staff_invitation_confirms_an_existing_account
    other = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    invitation = uc(:invite_member).call(other[:actor], email: "dona@alfa.test", role: "manager")
    token = "#{other[:organization_id]}.segredo-#{invitation["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invitation["id"]],
                tenant: other[:organization_id])

    refused { uc(:invite_member).call(@actor, email: "novo@alfa.test", role: "attendant") }
    uc(:accept_invitation).call(token: token, user_id: @org[:user_id])

    assert_equal "novo@alfa.test", uc(:invite_member).call(@actor, email: "novo@alfa.test", role: "attendant")["email"]
    @clock.advance(EC::GRACE_PERIOD_SECONDS)

    refute_nil uc(:create_customer).call(@actor, { kind: "individual", name: "Depois do Prazo", document: "39053344705" })
  end

  def test_accepting_a_portal_invitation_confirms_an_existing_account
    other = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    customer = create_customer(other[:actor], name: "Cliente Beta")
    contact = portal_contact(other[:actor], customer, email: "dona@alfa.test", name: "Dona Alfa")
    token = invite_and_deliver(other[:actor], customer, contact)

    uc(:accept_portal_invitation).call(token: token, user_id: @org[:user_id])

    assert_equal EC::CONFIRMED, @system.uow.run(@actor) { |_tx, current| current.email_status }
  end

  # Credencial criada por conta ainda não confirmada (por exemplo, pela 1.3.0 durante a implantação gradual):
  # herda a situação de quem a criou, como as sessões. Credencial sem criador não tem situação de e-mail.
  def test_credentials_follow_the_email_status_of_their_creator
    confirm_email(@org[:user_id])
    token = uc(:create_credential).call(@actor, name: "ERP", scopes: %w[quotes.write customers.write customers.read])["token"]
    owner_query("UPDATE users SET email_confirmed_at = NULL WHERE id = $1", [@org[:user_id]], tenant: "")
    api = uc(:authenticate_credential).call(token, kind: "api")
    quote = quote_draft

    error = refused { uc(:send_quote).call(api, quote.id) }

    assert_includes error.message, "enviar orçamentos aos clientes"
    refute_nil uc(:create_customer).call(api, { kind: "individual", name: "Pela Integração", document: "39053344705" }), "operação interna liberada"
    @clock.advance(EC::GRACE_PERIOD_SECONDS)

    refused(:read_only) { uc(:create_customer).call(api, { kind: "individual", name: "Depois do Prazo", document: "11144477735" }) }

    assert_equal 2, uc(:list_customers).call(api).total, "consultas liberadas"
    owner_query("UPDATE api_credentials SET created_by = NULL", [])

    assert_equal "Sem Criador", uc(:create_customer).call(api, { kind: "individual", name: "Sem Criador", document: "11144477735" }).name
    owner_query("UPDATE api_credentials SET created_by = $1", [@org[:user_id]])
    confirm_email(@org[:user_id])

    fresh = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, period: rental(20), lines: [line(@camera, 1)],
                                             valid_until: t("2026-03-15T12:00:00Z") })

    assert_equal "sent", uc(:send_quote).call(api, fresh.id).status
  end

  def test_new_accounts_created_by_invitations_are_born_confirmed
    confirm_email(@org[:user_id])
    member = staff_member(@org, "gerente@alfa.test", "manager")
    portal = portal_customer(@actor, @customer, email: "compras@cliente.test")
    @clock.advance(EC::GRACE_PERIOD_SECONDS * 2)

    assert_equal EC::CONFIRMED, @system.uow.run(member) { |_tx, current| current.email_status }
    assert_equal :already_confirmed, uc(:resend_email_confirmation).call(user_id: portal.user_id)
    refute_nil uc(:create_customer).call(member, { kind: "individual", name: "Pelo Gerente", document: "39053344705" })
  end
end
