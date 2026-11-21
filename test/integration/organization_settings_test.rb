# frozen_string_literal: true

require_relative "integration_helper"
require_relative "../support/operations_support"
require_relative "../support/portal_support"
require_relative "../support/organization_settings_support"

# Configurações da organização de ponta a ponta: quem altera e quem lê, isolamento por organização, a
# política de cancelamento congelada na reserva e na
# versão do orçamento (o contrato copia a da reserva), a validade padrão do bloqueio e as consequências
# da troca de fuso (preços, extensões, multas, vencimentos, contratos e aditivos no fuso de referência
# da reserva; reservas novas no fuso novo).
class OrganizationSettingsFlowTest < DatabaseTest
  include OperationsSupport
  include PortalHelpers
  include OrganizationSettingsSupport

  POLICY_B = { "tiers" => [{ "min_hours_before" => 48, "fee_bps" => 2000 }, { "min_hours_before" => 0, "fee_bps" => 5000 }] }.freeze
  ROWS_B = [%w[48 20], %w[0 50]].freeze
  SAO_PAULO = D::TimeZone.new("America/Sao_Paulo")

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-CFG", tracking: "serialized", pricing: { "daily_cents" => 10_000 })
    register_assets(@actor, @camera, @branch, 3)
  end

  def window(day) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
  def book(day, mode: "confirm", **) = reserve(@actor, @customer, @branch, window(day), [line(@camera, 1)], mode: mode, **)
  def policy_of(reservation) = uc(:get_reservation).call(@actor, reservation.id)[:cancellation_policy]
  def terms_of(contract) = uc(:get_contract).call(@actor, contract.id)[:contract].terms
  def default_policy = D::Organizations::CancellationPolicy::DEFAULT

  def quote_input(day, **extra)
    { customer_id: @customer.id, branch_id: @branch.id, period: window(day), lines: [line(@camera, 1)], valid_until: t("2026-03-05T12:00:00Z") }
      .merge(extra)
  end

  def approve(quote, version)
    uc(:send_quote).call(@actor, quote.id)
    uc(:approve_quote).call(@actor, quote.id, version: version, approver_name: "Maria Compradora")
  end

  def settings_events
    owner_query("SELECT actor_id, details FROM audit_events WHERE action = 'organization.settings_updated' ORDER BY occurred_at, id")
      .map { |row| [row["actor_id"], JSON.parse(row["details"])] }
  end

  # Papéis e isolamento -------------------------------------------------------------------------------

  def test_owner_and_admin_change_the_settings_with_before_and_after_in_the_audit
    admin = staff_member(@org, "admin@alfa.test", "admin")
    change_settings(hold_minutes: "45")
    renamed = change_settings(actor: admin, name: "Locadora Alfa Eventos", lock_version: 2)

    assert_equal ["Locadora Alfa Eventos", 3, 45], [renamed.name, renamed.lock_version, current_organization.hold_minutes]
    assert_equal [[@org[:user_id], { "changes" => { "hold_minutes" => [30, 45] }, "lock_version" => 2 }],
                  [admin.user_id, { "changes" => { "name" => ["Locadora Alfa", "Locadora Alfa Eventos"] }, "lock_version" => 3 }]], settings_events
  end

  def test_other_roles_and_credentials_cannot_change_the_settings_but_every_role_reads_them
    %w[manager attendant stock_operator finance auditor].each do |role|
      member = staff_member(@org, "#{role}@alfa.test", role)

      assert_raises(D::AccessDenied, role) { change_settings(actor: member, hold_minutes: "45") }
      assert_equal "Locadora Alfa", uc(:read_organization).call(member)[:organization].name, role
    end
    token = uc(:create_credential).call(@actor, name: "Terminal", scopes: %w[organization.manage organization.read], kind: "cli",
                                                expires_in_days: 30)["token"]
    cli = uc(:authenticate_credential).call(token)
    error = assert_raises(D::AccessDenied) { uc(:update_organization_settings).call(cli, settings_attrs(current_organization, hold_minutes: "45")) }

    assert_equal "as configurações da organização são alteradas somente por usuários", error.message
    assert_equal [1, 30], [uc(:read_organization).call(cli)[:organization].lock_version, current_organization.hold_minutes]
    assert_empty settings_events
  end

  def test_settings_and_branches_are_isolated_by_organization
    beta = create_organization(name: "Locadora Beta", email: "dona@beta.test")
    change_settings(hold_minutes: "45")
    intruder = beta[:actor]

    assert_equal [30, 45], [current_organization(intruder).hold_minutes, current_organization.hold_minutes]
    assert_raises(D::NotFound) { uc(:get_branch).call(intruder, @branch.id) }
    assert_raises(D::NotFound) { uc(:update_branch).call(intruder, @branch.id, name: "Invasora", address: nil) }
    assert_raises(D::NotFound) { uc(:set_branch_active).call(intruder, @branch.id, active: false) }
    branch = uc(:get_branch).call(@actor, @branch.id)[:branch]

    assert_equal [true, 1, "Matriz"], [branch.active, branch.lock_version, branch.name]
  end

  # Snapshot da política -----------------------------------------------------------------------------

  def test_contract_issued_after_a_policy_change_keeps_the_reservation_policy
    reservation = book(10)
    change_settings(cancellation_rows: ROWS_B)
    terms = terms_of(uc(:issue_contract).call(@actor, reservation.id))

    assert_equal default_policy, policy_of(reservation)
    assert_equal default_policy, terms["cancellation_policy"]
    assert_equal D::Organizations::CancellationPolicy.describe(default_policy), terms["cancellation_terms"]
    contract = uc(:issue_contract).call(@actor, reservation.id)
    preview = uc(:preview_contract_cancellation).call(@actor, contract.id)

    assert_equal [default_policy, 0], [preview.policy, preview.fee_bps], "a prévia usa a política do contrato (A)"
    fresh = book(12)
    fresh_terms = terms_of(uc(:issue_contract).call(@actor, fresh.id))

    assert_equal [POLICY_B, POLICY_B], [policy_of(fresh), fresh_terms["cancellation_policy"]]
    assert_includes fresh_terms["cancellation_terms"], "48 h ou mais antes do início: multa de 20% do valor contratado"
  end

  def test_quote_without_hold_converts_with_the_version_policy_and_a_revision_applies_the_new_one
    quote = uc(:create_quote).call(@actor, quote_input(10))
    change_settings(cancellation_rows: ROWS_B)
    approve(quote, 1)
    converted = uc(:convert_quote).call(@actor, quote.id)
    contract = uc(:issue_contract).call(@actor, converted.reservation.id)

    assert_equal [default_policy, default_policy], [policy_of(converted.reservation), terms_of(contract)["cancellation_policy"]]
    open_quote = uc(:create_quote).call(@actor, quote_input(12))
    change_settings(cancellation_rows: [%w[24 10], %w[0 60]])
    revised = uc(:revise_quote).call(@actor, open_quote.id, quote_input(12))
    versions = uc(:get_quote).call(@actor, open_quote.id)[:versions].to_h { |version| [version.number, version.cancellation_policy] }

    assert_equal 2, revised.current_version, "a revisão sem outra mudança é aceita depois da troca de política"
    assert_equal({ 1 => POLICY_B, 2 => { "tiers" => [{ "min_hours_before" => 24, "fee_bps" => 1000 }, { "min_hours_before" => 0, "fee_bps" => 6000 }] } },
                 versions)
    error = assert_raises(D::ValidationError) { uc(:revise_quote).call(@actor, open_quote.id, quote_input(12)) }

    assert_equal ["nenhuma alteração em relação à versão 2"], error.errors["base"]
  end

  def test_conversion_after_an_expired_send_hold_uses_the_version_policy
    quote = uc(:create_quote).call(@actor, quote_input(10, hold_policy: "hold_on_send", hold_minutes: 60))
    approve(quote, 1)
    hold = uc(:get_quote).call(@actor, quote.id)[:hold]

    assert_equal default_policy, policy_of(hold), "o bloqueio do envio recebe a política da versão"
    change_settings(cancellation_rows: ROWS_B)
    @clock.travel_to(@clock.now + 7200)
    converted = uc(:convert_quote).call(@actor, quote.id)

    refute_equal hold.id, converted.reservation.id, "o bloqueio vencido dá lugar a uma reserva nova"
    assert_equal default_policy, policy_of(converted.reservation)
  end

  def test_portal_request_keeps_the_policy_of_the_request_after_confirmation
    portal = portal_actor(@customer)
    request = uc(:portal_request_reservation).call(portal, branch_id: @branch.id, period: window(10), lines: [line(@camera, 1)])
    change_settings(cancellation_rows: ROWS_B)
    uc(:confirm_reservation).call(@actor, request.id)

    assert_equal "confirmed", reservation_status(request)
    assert_equal default_policy, policy_of(request)
  end

  def test_hold_validity_default_applies_only_to_new_records
    held = book(10, mode: "hold")
    draft = uc(:create_quote).call(@actor, quote_input(12, hold_policy: "hold_on_send"))
    change_settings(hold_minutes: "90")
    fresh = book(14, mode: "hold")

    assert_equal [@clock.now + 1800, @clock.now + 5400], [held.hold_expires_at, fresh.hold_expires_at]
    assert_equal(@clock.now + 1800, uc(:get_reservation).call(@actor, held.id)[:reservation].hold_expires_at)
    assert_equal [30, 90], [draft.hold_minutes, uc(:create_quote).call(@actor, quote_input(16, hold_policy: "hold_on_send")).hold_minutes]
    assert_equal 30, uc(:get_quote).call(@actor, draft.id)[:quote].hold_minutes
  end

  # Fuso -------------------------------------------------------------------------------------------

  def calendar_product
    create_product(@actor, sku: "TEN-CFG", tracking: "serialized", pricing: { "daily_cents" => 10_000, "daily_mode" => "calendar_day" })
  end

  # Retirada às 00:30 em São Paulo (23:30 do dia anterior em Manaus) e devolução às 23:00.
  def night_rental = period("2026-03-10T03:30:00Z", "2026-03-11T02:00:00Z")

  def test_existing_reservation_keeps_the_reference_time_zone_after_the_change
    tent = calendar_product
    register_assets(@actor, tent, @branch, 2)
    reservation = reserve(@actor, @customer, @branch, night_rental, [line(tent, 1)], mode: "confirm")
    change_settings(timezone: "America/Manaus", confirm_timezone_change: true)
    details = uc(:get_reservation).call(@actor, reservation.id)

    assert_equal [10_000, night_rental], [details[:reservation].total.cents, details[:reservation].period], "preço e período não mudam"
    contract = uc(:issue_contract).call(@actor, reservation.id)
    terms = terms_of(contract)

    assert_equal ["America/Sao_Paulo", "10/03/2026 00:30", "America/Sao_Paulo"],
                 [terms["period"]["timezone"], terms["period"]["starts_at_local"], terms["organization"]["timezone"]]
    extension = extension_in_sao_paulo(reservation)
    amended = uc(:amend_contract).call(@actor, contract.id, ends_at: extended_end)

    assert_equal extension, amended[:adjustment].cents, "a extensão é calculada em São Paulo"
    assert_equal ["10/03/2026 23:00", "11/03/2026 23:30", "Extensão da devolução de 10/03/2026 23:00 para 11/03/2026 23:30"],
                 [*amended[:amendment]["changes"].values_at("from_end_local", "to_end_local"), amended[:amendment]["description"]]
    assert_equal SAO_PAULO.format_local(@clock.now), amended[:document]["data_snapshot"]["generated_at_local"]
    assert_late_fee_and_due_dates_in_sao_paulo(reservation)
  end

  # Fim estendido para 23:30 de 11/03 em São Paulo (22:30 em Manaus): dois dias em São Paulo, três em Manaus.
  def extended_end = t("2026-03-12T02:30:00Z")

  def extension_in_sao_paulo(reservation)
    item = uc(:get_reservation).call(@actor, reservation.id)[:items].first
    deltas = [SAO_PAULO, D::TimeZone.new("America/Manaus")].map do |zone|
      D::Pricing::Extension.adjustment(line_snapshot: item["pricing"], new_period: D::Period.new(night_rental.starts_at, extended_end), zone: zone)
                           .first.cents
    end

    assert_equal [10_000, 20_000], deltas, "a extensão difere entre os fusos"
    deltas.first
  end

  def assert_late_fee_and_due_dates_in_sao_paulo(reservation)
    @clock.travel_to(night_rental.starts_at)
    pick_up(reservation)
    @clock.travel_to(extended_end + 3600)
    return_all(reservation)
    table = D::Pricing::PriceTable.from_h(uc(:get_reservation).call(@actor, reservation.id)[:items].first["pricing"]["table"])
    late = %w[America/Sao_Paulo America/Manaus].map do |zone|
      D::Pricing::LateFee.calculate(table: table, scheduled_end: extended_end, returned_at: @clock.now, quantity: 1, zone: D::TimeZone.new(zone)).cents
    end
    fee = owner_query("SELECT amount_cents FROM reservation_adjustments WHERE reservation_id = $1 AND kind = 'late_fee'", [reservation.id])

    refute_equal late.first, late.last, "o atraso cruza a meia-noite só em São Paulo"
    assert_equal [late.first], fee.map { |row| row["amount_cents"].to_i }, "a multa por atraso usa São Paulo"
    uc(:sync_reservation_charges).call(@actor, reservation.id)
    due = owner_query("SELECT kind, due_on::text FROM receivables WHERE reservation_id = $1 ORDER BY kind", [reservation.id]).to_h(&:values)

    assert_equal "2026-03-10", due["rental"], "vencimento da locação no dia local de São Paulo (23:30 do dia 9 em Manaus)"
  end

  def test_new_reservation_after_the_change_is_priced_in_the_new_time_zone
    tent = calendar_product
    register_assets(@actor, tent, @branch, 1)
    change_settings(timezone: "America/Manaus", confirm_timezone_change: true)
    crossing = period("2026-03-10T12:00:00Z", "2026-03-11T03:30:00Z") # 00:30 em São Paulo, 23:30 em Manaus
    reservation = reserve(@actor, @customer, @branch, crossing, [line(tent, 1)], mode: "confirm")
    summary = uc(:get_reservation).call(@actor, reservation.id)[:pricing][:summary]

    assert_equal [10_000, "America/Manaus"], [reservation.total.cents, summary["timezone"]], "um dia de calendário em Manaus (dois em São Paulo)"
    terms = terms_of(uc(:issue_contract).call(@actor, reservation.id))

    assert_equal ["America/Manaus", "10/03/2026 08:00"], [terms["period"]["timezone"], terms["period"]["starts_at_local"]]
  end
end
