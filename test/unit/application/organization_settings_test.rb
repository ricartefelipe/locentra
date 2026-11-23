# frozen_string_literal: true

require_relative "../unit_helper"

# Casos de uso de configurações da organização e de filiais com portas em memória (sem banco): papel do
# ator, controle otimista, operações nulas, prévia sem gravação, regras de desativação, limite do plano,
# filial ativa para novos vínculos e histórico condicionado à permissão.
class OrganizationSettingsApplicationTest < UnitTest
  A = Locentra::Application
  O = A::Organizations
  D = Domain::Organizations
  ORG_ID = "00000000-0000-7000-8000-0000000000a1"
  BRANCH_ID = "00000000-0000-7000-8000-0000000000b1"
  OTHER_ID = "00000000-0000-7000-8000-0000000000b2"
  ROWS = [%w[72 0], %w[24 30], %w[0 100]].freeze

  class Tx
    def tenant_id! = ORG_ID
  end

  class Uow
    def run(actor, permission = nil, read: false)
      A::Authorizer.authorize!(actor, permission, read: read) if permission
      yield Tx.new, actor
    end
  end

  class Audit
    attr_reader :records

    def initialize = @records = []
    def record(_tx, _actor, action, type, id, details = {}) = @records << [action, type, id, details]
  end

  class AuditLog
    attr_reader :reads

    def initialize = @reads = []

    def for_resource(_tx, type, id)
      @reads << [type, id]
      [{ "action" => "branch.created" }]
    end
  end

  # Organização e filiais em memória, com o controle otimista do repositório real.
  class Organizations
    attr_accessor :org, :branches, :concurrent_change, :commitments, :active_count
    attr_reader :calls

    def initialize(org, branches)
      @org = org
      @branches = branches.to_h { |branch| [branch.id, branch] }
      @calls = []
      @commitments = {}
    end

    def find(_tx, _id) = @org

    def lock(_tx, _id)
      @calls << :lock
      @org
    end

    def update_settings(_tx, org, expected, _now)
      @calls << :update_settings
      return 0 if @concurrent_change || @org.lock_version != expected

      @org = org
      1
    end

    def find_branch(_tx, id, lock: nil)
      @calls << [:find_branch, lock]
      @branches[id]
    end

    def lock_branch(tx, id) = find_branch(tx, id, lock: :update)

    def update_branch(_tx, branch, expected, _now)
      @calls << :update_branch
      return 0 if @concurrent_change || @branches.fetch(branch.id).lock_version != expected

      @branches[branch.id] = branch
      1
    end

    def active_branch_count(_tx) = @active_count || @branches.values.count(&:active)
    def branch_commitments(_tx, _id, _now) = @commitments
    def branch_usage(_tx, _id) = { assets: 2, stock_units: 5 }
    def timezone_impact(_tx, _now) = { open_reservations: 1, open_contracts: 0, scheduled_terms: 3 }
  end

  class Limits
    attr_accessor :error
    attr_reader :calls

    def initialize = @calls = []

    def ensure!(_tx, kind)
      @calls << kind
      raise @error if @error

      true
    end
  end

  def now = t("2026-03-02T12:00:00Z")
  def clock = TestClock.new(now)
  def owner = A::Actor.user(user_id: "u1", organization_id: ORG_ID, role: "owner")
  def manager = A::Actor.user(user_id: "u2", organization_id: ORG_ID, role: "manager")
  def auditor = A::Actor.user(user_id: "u3", organization_id: ORG_ID, role: "auditor")

  def credential(scopes = %w[organization.manage organization.read])
    A::Actor.credential(kind: "cli", credential_id: "c1", organization_id: ORG_ID, scopes: scopes)
  end

  def organization(**attrs)
    D::Organization.new(id: ORG_ID, name: "Locadora Alfa", slug: "locadora-alfa", timezone: "America/Sao_Paulo", status: "active", settings: {},
                        **attrs)
  end

  def branch(id = BRANCH_ID, code: "MATRIZ", active: true)
    D::Branch.new(id: id, organization_id: ORG_ID, name: "Filial #{code}", code: code, address: nil, active: active,
                  deactivated_at: active ? nil : now - 60)
  end

  def setup
    @repo = Organizations.new(organization, [branch, branch(OTHER_ID, code: "NORTE")])
    @audit = Audit.new
    @log = AuditLog.new
    @limits = Limits.new
  end

  def attrs(**changes) = { name: "Locadora Alfa", timezone: "America/Sao_Paulo", hold_minutes: "30", cancellation_rows: ROWS }.merge(changes)
  def update = O::UpdateSettings.new(uow: Uow.new, organizations: @repo, audit: @audit, clock: clock)
  def set_active = O::SetBranchActive.new(uow: Uow.new, organizations: @repo, limits: @limits, audit: @audit, clock: clock)
  def update_branch = O::UpdateBranch.new(uow: Uow.new, organizations: @repo, audit: @audit, clock: clock)
  def branch_reader = O::GetBranch.new(uow: Uow.new, organizations: @repo, audit_log: @log, clock: clock)
  def conflict(&) = assert_raises(Domain::Conflict, &)

  # Configurações ---------------------------------------------------------------------------------------

  def test_credentials_never_change_the_settings_even_with_the_scope
    error = assert_raises(Domain::AccessDenied) { update.call(credential, attrs(hold_minutes: "60")) }

    assert_equal "as configurações da organização são alteradas somente por usuários", error.message
    assert_raises(Domain::AccessDenied) { update.call(credential([]), attrs) }
    assert_raises(Domain::AccessDenied) { update.call(manager, attrs) }
    assert_empty @audit.records
    refute_includes @repo.calls, :update_settings
  end

  def test_update_records_the_changes_with_the_new_version
    result = update.call(owner, attrs(hold_minutes: "60", timezone: "America/Manaus", confirm_timezone_change: true), lock_version: "1")

    assert_equal [true, 2, 60, "America/Manaus"], [result.changed, result.record.lock_version, result.record.hold_minutes, result.record.timezone]
    assert_equal %i[lock update_settings], @repo.calls
    action, type, id, details = @audit.records.first

    assert_equal ["organization.settings_updated", "organization", ORG_ID], [action, type, id]
    assert_equal({ "changes" => { "timezone" => ["America/Sao_Paulo", "America/Manaus"], "hold_minutes" => [30, 60] }, "lock_version" => 2,
                   "timezone_confirmed" => true }, details)
  end

  def test_stale_version_and_lost_update_are_conflicts_without_audit
    assert_equal "stale_organization", conflict { update.call(owner, attrs(hold_minutes: "60"), lock_version: "7") }.code
    refute_includes @repo.calls, :update_settings
    @repo.concurrent_change = true
    error = conflict { update.call(owner, attrs(hold_minutes: "60"), lock_version: " ") }

    assert_equal ["stale_organization", O::STALE_ORGANIZATION], [error.code, error.message]
    assert_empty @audit.records
  end

  def test_partial_attributes_keep_the_other_values_and_via_goes_to_the_audit
    @repo.org = organization(settings: { "cancellation_policy" => { "tiers" => [{ "min_hours_before" => 0, "fee_bps" => 5000 }] } })
    result = update.call(owner, { hold_minutes: 90 }, lock_version: 1, via: "api")

    assert_equal [true, 90, "Locadora Alfa", "America/Sao_Paulo"], [result.changed, result.record.hold_minutes, result.record.name, result.record.timezone]
    assert_equal({ "tiers" => [{ "min_hours_before" => 0, "fee_bps" => 5000 }] }, result.record.cancellation_policy, "a política não muda")
    assert_equal({ "changes" => { "hold_minutes" => [30, 90] }, "lock_version" => 2, "via" => "api" }, @audit.records.first.last)
    tiers = update.call(owner, { cancellation_tiers: [{ "min_hours_before" => 24, "fee_bps" => 0 }, { "min_hours_before" => 0, "fee_bps" => 8000 }] },
                        lock_version: 2)

    assert_equal [90, 3], [tiers.record.hold_minutes, tiers.record.lock_version]
    refute @audit.records.last.last.key?("via"), "sem canal informado (web), os detalhes não mudam"
    assert_equal [false, 3], [update.call(owner, {}, lock_version: 3).changed, @repo.org.lock_version]
  end

  def test_credentials_are_refused_also_in_the_composed_mode
    error = assert_raises(Domain::AccessDenied) { update.call(credential, { hold_minutes: 90 }, tx: Tx.new) }

    assert_equal "as configurações da organização são alteradas somente por usuários", error.message
    assert_equal "permissão necessária: organization.manage",
                 assert_raises(Domain::AccessDenied) { update.call(credential(%w[organization.read]), {}, tx: Tx.new) }.message
    assert_raises(Domain::AccessDenied) { update.call(manager, { hold_minutes: 90 }, tx: Tx.new) }
    assert_equal [true, 90], [update.call(owner, { hold_minutes: 90 }, tx: Tx.new).changed, @repo.org.hold_minutes]
    assert_empty(@audit.records.reject { |record| record.last["changes"] == { "hold_minutes" => [30, 90] } })
  end

  def test_unchanged_settings_are_not_written
    result = update.call(owner, attrs, lock_version: 1)

    assert_equal [false, 1], [result.changed, result.record.lock_version]
    refute_includes @repo.calls, :update_settings
    assert_empty @audit.records
  end

  def test_preview_validates_without_writing_and_without_confirmation
    preview = O::PreviewSettings.new(uow: Uow.new, organizations: @repo)
                                .call(owner, attrs(timezone: "America/Manaus", confirm_timezone_change: false, cancellation_rows: [%w[0 50]]))

    assert_equal [true, "America/Manaus", 2], [preview[:timezone_changed], preview[:revised].timezone, preview[:revised].lock_version]
    assert_same @repo.org, preview[:current]
    assert_empty @repo.calls
    assert_raises(Domain::AccessDenied) { O::PreviewSettings.new(uow: Uow.new, organizations: @repo).call(manager, attrs) }
  end

  def test_get_settings_returns_impact_and_history
    data = O::GetSettings.new(uow: Uow.new, organizations: @repo, audit_log: @log, clock: clock).call(owner)

    assert_equal [{ open_reservations: 1, open_contracts: 0, scheduled_terms: 3 }, now], [data[:impact], data[:now]]
    assert_equal [["organization", ORG_ID]], @log.reads
    assert_raises(Domain::AccessDenied) { O::GetSettings.new(uow: Uow.new, organizations: @repo, audit_log: @log, clock: clock).call(manager) }
  end

  # Filiais ---------------------------------------------------------------------------------------------

  def test_set_branch_active_without_change_is_a_no_op
    result = set_active.call(owner, BRANCH_ID, active: true)

    assert_equal [false, true], [result.changed, result.record.active]
    assert_empty @audit.records
    assert_empty @limits.calls
  end

  def test_last_active_branch_cannot_be_deactivated
    @repo.branches[OTHER_ID] = branch(OTHER_ID, code: "NORTE", active: false)
    error = conflict { set_active.call(owner, BRANCH_ID, active: false) }

    assert_equal ["last_active_branch", "A organização precisa de ao menos uma filial ativa."], [error.code, error.message]
    assert_equal [%i[find_branch update], :lock], @repo.calls, "a filial é travada antes da organização"
  end

  def test_branch_in_use_lists_the_commitments
    @repo.commitments = { reservations: { count: 1, codes: ["R-000001"] } }
    error = conflict { set_active.call(owner, BRANCH_ID, active: false) }

    assert_equal "branch_in_use", error.code
    assert_equal "Não é possível desativar a filial MATRIZ: 1 reserva em aberto (R-000001): conclua ou cancele.", error.message
    refute_includes @repo.calls, :update_branch
  end

  def test_deactivation_and_reactivation_are_audited_and_reactivation_respects_the_plan
    deactivated = set_active.call(owner, BRANCH_ID, active: false)

    assert_equal [true, false, now, 2], [deactivated.changed, deactivated.record.active, deactivated.record.deactivated_at, deactivated.record.lock_version]
    @limits.error = Domain::PlanLimitExceeded.new("branches", "Limite de filiais do plano Profissional atingido (1)")

    assert_raises(Domain::PlanLimitExceeded) { set_active.call(owner, BRANCH_ID, active: true) }
    @limits.error = nil
    reactivated = set_active.call(owner, BRANCH_ID, active: true)

    assert_equal [true, true, nil], [reactivated.changed, reactivated.record.active, reactivated.record.deactivated_at]
    assert_equal([%w[branch.deactivated branch], %w[branch.reactivated branch]], @audit.records.map { |record| record.first(2) })
    assert_equal({ "code" => "MATRIZ" }, @audit.records.last.last)
    assert_equal %i[branches branches], @limits.calls
  end

  def test_update_branch_with_stale_version_and_changes
    assert_equal "stale_branch", conflict { update_branch.call(owner, BRANCH_ID, name: "Sede", address: nil, lock_version: "3") }.code
    unchanged = update_branch.call(owner, BRANCH_ID, name: "Filial MATRIZ", address: "", lock_version: "1")

    refute unchanged.changed
    result = update_branch.call(owner, BRANCH_ID, name: "Sede", address: "Rua A", lock_version: "1")

    assert_equal [true, "Sede", 2], [result.changed, result.record.name, result.record.lock_version]
    assert_equal([["branch.updated", { "code" => "MATRIZ", "changes" => { "name" => ["Filial MATRIZ", "Sede"], "address" => [nil, "Rua A"] } }]],
                 @audit.records.map { |record| [record.first, record.last] })
    assert_raises(Domain::NotFound) { update_branch.call(owner, "00000000-0000-7000-8000-0000000000ff", name: "Sede", address: nil) }
  end

  def test_branch_guard_refuses_missing_and_inactive_branches
    @repo.branches[OTHER_ID] = branch(OTHER_ID, code: "NORTE", active: false)
    missing = assert_raises(Domain::NotFound) { O::BranchGuard.active!(@repo, Tx.new, "00000000-0000-7000-8000-0000000000ff", field: "filial") }
    inactive = assert_raises(Domain::ValidationError) { O::BranchGuard.active!(@repo, Tx.new, OTHER_ID, field: "destino") }

    assert_equal "filial não encontrada", missing.message
    assert_equal({ "destino" => ["filial inativa: escolha uma filial ativa"] }, inactive.errors)
    assert_equal BRANCH_ID, O::BranchGuard.active!(@repo, Tx.new, BRANCH_ID, field: "filial").id
    O::BranchGuard.active!(@repo, Tx.new, BRANCH_ID, field: "filial", lock: false)

    assert_equal [%i[find_branch share], %i[find_branch share], %i[find_branch share], [:find_branch, nil]], @repo.calls
    assert_equal({ "filial" => ["identificador inválido"] },
                 assert_raises(Domain::ValidationError) { O::BranchGuard.active!(@repo, Tx.new, "x", field: "filial") }.errors)
  end

  def test_branch_history_depends_on_the_permission
    with_history = [owner, auditor].map { |actor| branch_reader.call(actor, BRANCH_ID)[:history] }
    manager_data = branch_reader.call(manager, BRANCH_ID)

    assert_equal [[{ "action" => "branch.created" }]] * 2, with_history
    assert_nil manager_data[:history]
    assert_equal({ assets: 2, stock_units: 5 }, manager_data[:usage])
    assert_equal [["branch", BRANCH_ID]] * 2, @log.reads
    assert_raises(Domain::NotFound) { branch_reader.call(owner, "00000000-0000-7000-8000-0000000000ff") }
    assert_raises(Domain::AccessDenied) { branch_reader.call(credential([]), BRANCH_ID) }
  end
end
