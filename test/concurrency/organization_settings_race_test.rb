# frozen_string_literal: true

require_relative "concurrency_helper"
require_relative "../support/barrier"
require_relative "../support/organization_settings_support"

# Disputas reais nas configurações da organização e na situação das filiais, em conexões separadas
# sincronizadas por barreiras: controle otimista das configurações, desativação contra a criação de
# vínculos com a filial (FOR NO KEY UPDATE contra FOR SHARE, nas duas ordens), desativação das duas
# últimas filiais (trava da organização, mesmo sem assinatura), reativações no limite do plano (trava da
# assinatura) e política gravada numa reserva criada durante a alteração.
class OrganizationSettingsRaceTest < DatabaseTest
  include OrganizationSettingsSupport

  O = Locentra::Application::Organizations
  R = Locentra::Application::Reservations
  T = Locentra::Application::Transfers
  POLICY_A = Locentra::Domain::Organizations::CancellationPolicy::DEFAULT
  POLICY_B = { "tiers" => [{ "min_hours_before" => 48, "fee_bps" => 2000 }, { "min_hours_before" => 0, "fee_bps" => 5000 }] }.freeze

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @main = @org[:branch]
    @north = uc(:create_branch).call(@actor, name: "Unidade Norte", code: "NORTE")
    @customer = create_customer(@actor)
    @chairs = create_product(@actor, sku: "CAD-CFG", tracking: "bulk", pricing: { "daily_cents" => 1_000 })
    stock(@actor, @chairs, @north, 10)
    stock(@actor, @chairs, @main, 10)
  end

  def repos = @system.repos
  def services = @system.services
  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
  def paused(method, barrier, after: false) = PausingProxy.new(repos[:organizations], method, barrier, after: after)

  def update_settings(organizations) = O::UpdateSettings.new(uow: @system.uow, organizations: organizations, audit: services[:audit], clock: @clock)

  def toggler(organizations)
    O::SetBranchActive.new(uow: @system.uow, organizations: organizations, limits: services[:limits], audit: services[:audit], clock: @clock)
  end

  def create_reservation(organizations)
    R::CreateReservation.new(uow: @system.uow, reservations: repos[:reservations], customers: repos[:customers], organizations: organizations,
                             allocator: services[:allocator], pricer: services[:pricer], audit: services[:audit], events: services[:events],
                             clock: @clock, ids: @system.ids)
  end

  def request_transfer(organizations)
    T::RequestTransfer.new(uow: @system.uow, transfers: repos[:transfers], catalog: repos[:catalog], allocations: repos[:operational_allocations],
                           organizations: organizations, audit: services[:audit], clock: @clock, ids: @system.ids)
  end

  def booking(branch = @north) = { customer_id: @customer.id, branch_id: branch.id, period: window, lines: [line(@chairs, 1)], mode: "confirm" }

  # Executa o bloco numa thread e devolve [resultado, detalhe], sem deixar a exceção escapar.
  def attempt
    Thread.new do
      [:ok, yield]
    rescue D::ValidationError => e
      [:validation, e.errors]
    rescue D::Conflict => e
      [:conflict, e.code]
    rescue D::PlanLimitExceeded => e
      [:limit, e.message]
    rescue D::Error => e
      [:error, e]
    end
  end

  def settings_events
    owner_query("SELECT details FROM audit_events WHERE action = 'organization.settings_updated' ORDER BY occurred_at, id")
      .map { |row| JSON.parse(row["details"]) }
  end

  def test_simultaneous_edits_with_the_same_version_keep_one_and_refuse_the_other
    org = current_organization
    update = update_settings(paused(:lock, Barrier.new(2)))
    outcomes = [{ hold_minutes: "45" }, { name: "Locadora Beta" }].map do |change|
      attempt { update.call(@actor, settings_attrs(org, **change), lock_version: "1").changed }
    end.map(&:value)

    assert_equal [[:conflict, "stale_organization"], [:ok, true]], outcomes.sort_by(&:first)
    assert_equal 2, current_organization.lock_version
    assert_equal 1, settings_events.size, "a edição recusada não grava nem audita"
  end

  def test_without_version_both_save_and_the_second_starts_from_the_first
    org = current_organization
    update = update_settings(paused(:lock, Barrier.new(2)))
    outcomes = [{ hold_minutes: "45" }, { name: "Locadora Beta" }].map { |change| attempt { update.call(@actor, settings_attrs(org, **change)).changed } }
                                                                  .map(&:value)
    first, second = settings_events

    assert_equal [[:ok, true]] * 2, outcomes
    assert_equal 3, current_organization.lock_version
    first.fetch("changes").each { |field, (_from, to)| assert_equal to, second.fetch("changes").fetch(field).first, field }
  end

  # Criação primeiro: a criação trava a filial (FOR SHARE) e pausa; a desativação espera a trava e encontra
  # a reserva. Desativação primeiro: a criação espera e relê a filial já inativa.
  def race_deactivation_against(create_first:, &creation)
    barrier = Barrier.new(2)
    creator = paused(:find_branch, barrier, after: create_first)
    deactivator = toggler(paused(:lock_branch, barrier, after: !create_first))
    threads = [attempt { yield(creator) }, attempt { deactivator.call(@actor, @north.id, active: false).changed }]
    threads.map(&:value)
  end

  def test_deactivation_against_reservation_creation_in_both_orders
    created, deactivated = race_deactivation_against(create_first: true) { |orgs| create_reservation(orgs).call(@actor, booking) }

    assert_equal [:ok, [:conflict, "branch_in_use"]], [created.first, deactivated]
    uc(:cancel_reservation).call(@actor, created.last.id, reason: "Nova tentativa")
    refused, deactivated = race_deactivation_against(create_first: false) { |orgs| create_reservation(orgs).call(@actor, booking) }

    assert_equal [:ok, true], deactivated
    assert_equal [:validation, { "filial" => ["filial inativa: escolha uma filial ativa"] }], refused
  end

  def test_deactivation_against_transfer_to_the_branch_in_both_orders
    transfer = ->(orgs) { request_transfer(orgs).call(@actor, to_branch_id: @north.id, product_id: @chairs.id, from_branch_id: @main.id, quantity: 1) }
    requested, deactivated = race_deactivation_against(create_first: true, &transfer)

    assert_equal [:ok, [:conflict, "branch_in_use"]], [requested.first, deactivated]
    uc(:cancel_transfer).call(@actor, requested.last.id, reason: "Nova tentativa")
    refused, deactivated = race_deactivation_against(create_first: false, &transfer)

    assert_equal [[:ok, true], [:validation, { "destino" => ["filial inativa: escolha uma filial ativa"] }]], [deactivated, refused]
  end

  def test_only_one_of_the_last_two_branches_is_deactivated_even_without_subscription
    owner_query("DELETE FROM subscriptions")
    toggle = toggler(paused(:lock_branch, Barrier.new(2), after: true))
    outcomes = [@main, @north].map { |branch| attempt { toggle.call(@actor, branch.id, active: false).changed } }.map(&:value)

    assert_equal [[:conflict, "last_active_branch"], [:ok, true]], outcomes.sort_by(&:first)
    assert_equal 1, uc(:get_organization).call(@actor)[:branches].count(&:active)
  end

  def test_two_reactivations_compete_for_the_last_slot_of_the_plan
    south = uc(:create_branch).call(@actor, name: "Unidade Sul", code: "SUL")
    uc(:set_branch_active).call(@actor, south.id, active: false)
    east = uc(:create_branch).call(@actor, name: "Unidade Leste", code: "LESTE")
    uc(:set_branch_active).call(@actor, east.id, active: false)
    toggle = toggler(paused(:lock_branch, Barrier.new(2), after: true))
    outcomes = [south, east].map { |branch| attempt { toggle.call(@actor, branch.id, active: true).changed } }.map(&:value)

    assert_equal [[:limit, "Limite de filiais do plano Profissional atingido (3)"], [:ok, true]], outcomes.sort_by(&:first)
    assert_equal 3, uc(:get_organization).call(@actor)[:branches].count(&:active)
  end

  def test_reservation_created_during_a_policy_change_keeps_exactly_one_of_the_policies
    org = current_organization
    barrier = Barrier.new(2)
    create = create_reservation(paused(:find, barrier, after: true))
    update = update_settings(paused(:lock, barrier))
    threads = [attempt { create.call(@actor, booking(@main)) },
               attempt { update.call(@actor, settings_attrs(org, cancellation_rows: [%w[48 20], %w[0 50]]), lock_version: "1").changed }]
    reservation, updated = threads.map(&:value)
    policy = uc(:get_reservation).call(@actor, reservation.last.id)[:cancellation_policy]

    assert_equal [:ok, true], updated
    assert_includes [POLICY_A, POLICY_B], policy
    assert_equal POLICY_A, policy, "a organização é lida uma única vez, antes da alteração"
    assert_equal POLICY_B, current_organization.cancellation_policy
  end
end
