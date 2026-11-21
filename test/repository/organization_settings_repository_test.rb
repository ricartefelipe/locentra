# frozen_string_literal: true

require_relative "repository_helper"
require_relative "../support/commercial_terms_support"

# Garantias do banco para as configurações da organização e a gestão de filiais, exercitadas com os papéis
# reais: privilégios por coluna, política de cancelamento imutável na reserva e na versão do orçamento,
# preenchimento de inserções no formato da 1.1.0, CHECKs de formato e as consultas do repositório de
# organizações (gravação com versão esperada, vínculos de filial, impacto da troca de fuso), sempre
# restritas ao tenant.
class OrganizationSettingsRepositoryTest < DatabaseTest
  include CommercialTermsSupport

  CUSTOM_POLICY = { "tiers" => [{ "min_hours_before" => 48, "fee_bps" => 1000 }, { "min_hours_before" => 0, "fee_bps" => 5000 }] }.freeze

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @chairs = create_product(@actor, sku: "CAD-CFG", tracking: "bulk", pricing: { "daily_cents" => 10_000 })
    stock(@actor, @chairs, @branch, 20)
  end

  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
  def book(day: 10, mode: "confirm") = reserve(@actor, @customer, @branch, window(day), [line(@chairs, 1)], mode: mode)
  def denied(sql, params = []) = assert_raises(D::AccessDenied, sql) { tenant_tx { |tx| tx.execute(sql, params) } }
  def check_violation(sql, params = []) = assert_raises(PG::CheckViolation, sql) { owner_query(sql, params) }
  def policy_of(table, id) = JSON.parse(owner_query("SELECT cancellation_policy FROM #{table} WHERE id = $1", [id]).first["cancellation_policy"])

  def quote_version_id
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, period: window(12), lines: [line(@chairs, 1)],
                                             valid_until: Time.utc(2026, 3, 5) })
    owner_query("SELECT id FROM quote_versions WHERE quote_id = $1", [quote.id]).first["id"]
  end

  # Reserva inserida pelo papel de aplicação sem a coluna cancellation_policy (formato da 1.1.0).
  def legacy_insert
    id = SecureRandom.uuid
    tenant_tx do |tx|
      tx.execute(<<~SQL, [id, @org[:organization_id], @branch.id, @customer.id, "L-#{id[0, 6]}", @clock.now])
        INSERT INTO reservations (id, organization_id, branch_id, customer_id, code, status, starts_at, ends_at, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, 'requested', '2026-04-01T08:00:00Z', '2026-04-02T08:00:00Z', $6, $6)
      SQL
    end
    id
  end

  def test_application_role_writes_only_the_editable_columns_of_organizations_and_branches
    org_id = @org[:organization_id]
    denied("UPDATE organizations SET slug = 'outro-slug' WHERE id = $1", [org_id])
    denied("UPDATE organizations SET status = 'suspended' WHERE id = $1", [org_id])
    denied("UPDATE organizations SET legal_document = '11222333000181' WHERE id = $1", [org_id])
    denied("DELETE FROM organizations WHERE id = $1", [org_id])
    denied("UPDATE branches SET code = 'OUTRO' WHERE id = $1", [@branch.id])
    denied("DELETE FROM branches WHERE id = $1", [@branch.id])
    denied("UPDATE quote_versions SET cancellation_policy = $1 WHERE id = $2", [CUSTOM_POLICY, quote_version_id])
    updated = tenant_tx do |tx|
      [tx.execute("UPDATE organizations SET name = 'Locadora Beta', settings = '{}', lock_version = 2, updated_at = now() WHERE id = $1", [org_id]),
       tx.execute("UPDATE branches SET name = 'Sede', address = 'Rua A', lock_version = 2, updated_at = now() WHERE id = $1", [@branch.id])]
    end

    assert_equal [1, 1], updated
  end

  def test_worker_role_neither_writes_nor_locks_organizations_and_branches
    privileges = owner_query(<<~SQL).first
      SELECT has_any_column_privilege('locentra_worker', 'organizations', 'UPDATE') AS org_update,
             has_any_column_privilege('locentra_worker', 'branches', 'UPDATE') AS branch_update,
             has_table_privilege('locentra_worker', 'branches', 'DELETE') AS branch_delete,
             has_column_privilege('locentra_app', 'branches', 'active', 'UPDATE') AS app_active,
             has_column_privilege('locentra_app', 'organizations', 'settings', 'UPDATE') AS app_settings
    SQL

    assert_equal %w[f f f t t], privileges.values
    conn = PG.connect(TestDatabase.worker_url)
    conn.exec_params("SELECT set_config('app.tenant_id', $1, false)", [@org[:organization_id]])

    assert_equal 1, conn.exec("SELECT id FROM branches").ntuples, "o worker lê as filiais"
    assert_raises(PG::InsufficientPrivilege) { conn.exec("SELECT id FROM branches FOR SHARE") }
  ensure
    conn&.close
  end

  def test_registered_cancellation_policies_are_immutable_even_for_the_owner
    reservation = book
    version = quote_version_id
    messages = [["reservations", reservation.id], ["quote_versions", version]].map do |table, id|
      check_violation("UPDATE #{table} SET cancellation_policy = $1 WHERE id = $2", [JSON.generate(CUSTOM_POLICY), id]).message[/ERROR:  ([^\n]+)/, 1]
    end

    assert_equal ["a política de cancelamento registrada não pode ser alterada"] * 2, messages
    assert_equal 1, owner_query("UPDATE reservations SET notes = 'Observação' WHERE id = $1 RETURNING id", [reservation.id]).size,
                 "as demais colunas continuam alteráveis"
  end

  def test_inserts_without_the_column_receive_the_settings_policy_or_the_default
    default_policy = JSON.parse(owner_query("SELECT app_default_cancellation_policy() AS p").first["p"])

    assert_equal D::Organizations::CancellationPolicy::DEFAULT, default_policy
    assert_equal default_policy, policy_of("reservations", legacy_insert)
    owner_query("UPDATE organizations SET settings = $1 WHERE id = $2", [JSON.generate("cancellation_policy" => CUSTOM_POLICY), @org[:organization_id]])

    assert_equal CUSTOM_POLICY, policy_of("reservations", legacy_insert)
    owner_query("UPDATE organizations SET settings = '{\"cancellation_policy\": null}' WHERE id = $1", [@org[:organization_id]])

    assert_equal default_policy, policy_of("reservations", legacy_insert), "JSON null equivale a ausente"
  end

  # A aplicação sempre informa a política: o gatilho de preenchimento é só para instâncias 1.1.0.
  def test_repositories_always_receive_the_policy_explicitly
    parameters = Locentra::Infrastructure::Persistence::ReservationRepository.instance_method(:insert).parameters

    assert_includes parameters, %i[keyreq cancellation_policy]
    quotes = @system.repos[:quotes]
    quote_id = owner_query("SELECT quote_id FROM quote_versions WHERE id = $1", [quote_version_id]).first["quote_id"]
    version = tenant_tx { |tx| quotes.find_version(tx, quote_id, 1) }

    assert_equal D::Organizations::CancellationPolicy::DEFAULT, version.cancellation_policy
    error = assert_raises(ArgumentError) { tenant_tx { |tx| quotes.insert_version(tx, version.with(cancellation_policy: nil), @actor.user_id) } }

    assert_equal "versão sem política de cancelamento", error.message
  end

  def test_shape_checks_refuse_malformed_policies_settings_and_branch_states
    invalid_shapes = ['{"tiers": []}', '{"tiers": {}}', '{"faixas": []}', '{"tiers": [{"min_hours_before": "24", "fee_bps": 0}]}', "[]", '{"tiers": [1]}']
    shape_ok = invalid_shapes.map { |shape| owner_query("SELECT app_cancellation_policy_shape_ok($1::jsonb) AS ok", [shape]).first["ok"] }

    assert_equal ["f"] * invalid_shapes.size, shape_ok
    assert_raises(PG::CheckViolation) do
      owner_query(<<~SQL, [SecureRandom.uuid, @org[:organization_id], @branch.id, @customer.id, @clock.now])
        INSERT INTO reservations (id, organization_id, branch_id, customer_id, code, status, starts_at, ends_at, created_at, updated_at,
                                  cancellation_policy)
        VALUES ($1, $2, $3, $4, 'X-1', 'requested', '2026-04-01T08:00:00Z', '2026-04-02T08:00:00Z', $5, $5, '{"tiers": []}')
      SQL
    end
    assert_raises(PG::CheckViolation) { owner_query("UPDATE organizations SET settings = '[]' WHERE id = $1", [@org[:organization_id]]) }
    assert_raises(PG::CheckViolation) { owner_query("UPDATE branches SET active = false WHERE id = $1", [@branch.id]) }
    assert_raises(PG::CheckViolation) { owner_query("UPDATE branches SET deactivated_at = now() WHERE id = $1", [@branch.id]) }
    assert_equal 1, owner_query("UPDATE branches SET active = false, deactivated_at = now() WHERE id = $1 RETURNING id", [@branch.id]).size
  end

  def repo = @system.repos[:organizations]
  def reservations = @system.repos[:reservations]

  def test_updates_with_the_expected_version_return_the_number_of_rows
    org = tenant_tx { |tx| repo.lock(tx, @org[:organization_id]) }
    revised = org.with(name: "Locadora Beta", lock_version: 2)
    branch = tenant_tx { |tx| repo.lock_branch(tx, @branch.id) }
    renamed = branch.with(name: "Sede", lock_version: 2)

    assert_equal [1, 0], [tenant_tx { |tx| repo.update_settings(tx, revised, 1, @clock.now) }, tenant_tx do |tx|
      repo.update_settings(tx, revised, 1, @clock.now)
    end]
    assert_equal [1, 0], [tenant_tx { |tx| repo.update_branch(tx, renamed, 1, @clock.now) }, tenant_tx { |tx| repo.update_branch(tx, renamed, 1, @clock.now) }]
    assert_equal(["Locadora Beta", 2], tenant_tx { |tx| repo.find(tx, @org[:organization_id]) }.then { |found| [found.name, found.lock_version] })
    assert_equal(["Sede", 2], tenant_tx { |tx| repo.find_branch(tx, @branch.id) }.then { |found| [found.name, found.lock_version] })
    assert_raises(ArgumentError) { tenant_tx { |tx| repo.find_branch(tx, @branch.id, lock: :exclusive) } }
  end

  def test_queries_and_locks_see_only_the_tenant
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    reservation = book

    assert_nil(tenant_tx { |tx| repo.lock(tx, beta[:organization_id]) })
    assert_nil(tenant_tx { |tx| repo.find_branch(tx, beta[:branch].id, lock: :share) })
    assert_nil(tenant_tx(beta) { |tx| reservations.cancellation_policy(tx, reservation.id) })
    assert_nil(tenant_tx(beta) { |tx| reservations.reference_timezone(tx, reservation.id) })
    assert_equal [1, 1], [tenant_tx { |tx| repo.active_branch_count(tx) }, tenant_tx(beta) { |tx| repo.active_branch_count(tx) }]
    assert_equal({ assets: 0, stock_units: 0 }, tenant_tx(beta) { |tx| repo.branch_usage(tx, @branch.id) })
    assert_equal 0, tenant_tx(beta) { |tx| repo.branch_commitments(tx, @branch.id, @clock.now) }[:reservations][:count]
    assert_equal({ open_reservations: 0, open_contracts: 0, scheduled_terms: 0 }, tenant_tx(beta) { |tx| repo.timezone_impact(tx, @clock.now) })
    assert_equal([D::Organizations::CancellationPolicy::DEFAULT, "America/Sao_Paulo"],
                 tenant_tx { |tx| [reservations.cancellation_policy(tx, reservation.id), reservations.reference_timezone(tx, reservation.id)] })
  end

  def quote_in(branch, valid_until:, send: true)
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: branch.id, period: window(20), lines: [line(@chairs, 1)],
                                             valid_until: valid_until })
    uc(:send_quote).call(@actor, quote.id) if send
    quote
  end

  def test_branch_commitments_count_only_what_blocks_the_deactivation
    north = uc(:create_branch).call(@actor, name: "Unidade Norte", code: "NORTE")
    stock(@actor, @chairs, north, 10)
    open = Array.new(6) { |i| reserve(@actor, @customer, north, window(10 + i), [line(@chairs, 1)], mode: "confirm") }
    reserve(@actor, @customer, north, window(18), [line(@chairs, 1)], mode: "hold", hold_minutes: 5)
    vigente = quote_in(north, valid_until: @clock.now + 7200)
    quote_in(north, valid_until: @clock.now + 600)
    quote_in(north, valid_until: @clock.now + 7200, send: false)
    incoming = uc(:request_transfer).call(@actor, to_branch_id: north.id, product_id: @chairs.id, from_branch_id: @branch.id, quantity: 1)
    uc(:request_transfer).call(@actor, to_branch_id: @branch.id, product_id: @chairs.id, from_branch_id: north.id, quantity: 1)
    @clock.travel_to(@clock.now + 1200)
    commitments = tenant_tx { |tx| repo.branch_commitments(tx, north.id, @clock.now) }

    assert_equal({ count: 6, codes: open.map(&:code).sort.first(5) }, commitments[:reservations], "o bloqueio vencido não conta")
    assert_equal({ count: 1, codes: [vigente.code] }, commitments[:sent_quotes], "orçamento enviado vencido e rascunho não contam")
    assert_equal({ count: 0, codes: [] }, commitments[:approved_quotes])
    assert_equal({ count: 1, codes: [incoming.code] }, commitments[:incoming_transfers], "a transferência de saída não conta")
    assert_equal({ assets: 0, stock_units: 10 }, tenant_tx { |tx| repo.branch_usage(tx, north.id) })
    assert_equal(2, tenant_tx { |tx| repo.active_branch_count(tx) })
  end

  def test_timezone_impact_counts_open_records_and_future_validities
    book(day: 10, mode: "hold") # vencido depois de uma hora: não conta
    book(day: 12)
    uc(:issue_contract).call(@actor, book(day: 14).id)
    create_coupon("FUTURO", valid_from: @clock.now + 86_400)
    create_coupon("ATEMAIO", valid_until: @clock.now + 86_400)
    create_coupon("SEMPRAZO")
    create_agreement(@customer, 500, valid_until: @clock.now + 86_400)
    @clock.travel_to(@clock.now + 3600)

    assert_equal({ open_reservations: 2, open_contracts: 1, scheduled_terms: 3 }, tenant_tx { |tx| repo.timezone_impact(tx, @clock.now) })
  end
end
