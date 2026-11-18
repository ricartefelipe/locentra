# frozen_string_literal: true

require_relative "integration_helper"

# Casos de uso usados pela CLI operacional, exercitados diretamente com atores de qualquer interface:
# identidade autenticada, busca por código/patrimônio, filtro por SKU e tarefas mortas.
class JobsLookupsTest < DatabaseTest
  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
  end

  def dead_job(last_error: nil)
    id = SecureRandom.uuid
    owner_query(<<~SQL, [id, @org[:organization_id], last_error])
      INSERT INTO jobs (id, organization_id, kind, status, attempts, max_attempts, last_error, run_at, created_at, updated_at, finished_at)
      VALUES ($1, $2, 'email.send', 'dead', 3, 3, $3, now(), now(), now(), now())
    SQL
    id
  end

  def test_whoami_for_staff_and_credential_actors
    staff = uc(:whoami).call(@actor)

    assert_nil staff[:credential]
    assert_equal ["owner", "Locadora Alfa"], [staff[:actor].role, staff[:organization].name]
    row = uc(:create_credential).call(@actor, name: "Rotina", scopes: %w[jobs.manage], kind: "cli", expires_in_days: 1)
    cli = uc(:authenticate_credential).call(row["token"], kind: "cli")
    info = uc(:whoami).call(cli)

    assert_equal [row["id"], "Rotina", "cli", %w[jobs.manage]], info[:credential].values_at("id", "name", "kind", "scopes")
    refute info[:credential].key?("token_digest")
    assert_nil uc(:authenticate_credential).call(row["token"], kind: "api"), "credencial cli não autentica como api"
  end

  def test_reference_lookups_require_a_reference_and_respect_permissions
    assert_raises(D::ValidationError) { uc(:get_reservation).by_reference(@actor, "  ") }
    assert_raises(D::ValidationError) { uc(:get_asset).by_reference(@actor, nil) }
    camera = create_product(@actor, sku: "CAM-REF", tracking: "serialized")
    asset = register_assets(@actor, camera, @org[:branch], 1).first

    assert_equal asset.id, uc(:get_asset).by_reference(@actor, "cam-ref-1")[:asset].id
    assert_equal asset.id, uc(:get_asset).by_reference(@actor, asset.id.upcase)[:asset].id
    assert_nil uc(:get_asset).call(@actor, asset.id)[:hold]
    reservation = reserve(@actor, create_customer(@actor), @org[:branch], period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z"), [line(camera, 1)])

    assert_equal reservation.id, uc(:get_reservation).by_reference(@actor, " #{reservation.code.downcase} ")[:reservation].id
    assert_raises(D::NotFound) { uc(:get_reservation).by_reference(@actor, "R-123456") }
  end

  def test_availability_filters_by_sku_without_duplicates
    camera = create_product(@actor, sku: "CAM-SKU", tracking: "serialized")
    register_assets(@actor, camera, @org[:branch], 2)
    window = period("2026-03-10T08:00:00Z", "2026-03-10T10:00:00Z")
    rows = uc(:check_availability).call(@actor, branch_id: @org[:branch].id, period: window, product_ids: [camera.id], skus: %w[cam-sku CAM-SKU])

    assert_equal([[camera.id, 2]], rows.map { |row| [row["product"].id, row["available"]] })
    error = assert_raises(D::ValidationError) { uc(:check_availability).call(@actor, branch_id: @org[:branch].id, period: window, skus: %w[NADA]) }

    assert_includes error.message, "SKU não encontrado: NADA"
  end

  def test_failed_jobs_listing_and_retry_by_staff
    id = dead_job
    redacted = dead_job(last_error: "Erro: https://api.example.test/hook?chave=1 token=abc")

    assert_equal({ id => nil, redacted => "Erro: https://api.example.test/hook?[parâmetros omitidos] token=[omitido]" },
                 uc(:list_failed_jobs).call(@actor).to_h { |row| [row["id"], row["last_error"]] })
    assert_equal({ "id" => id, "kind" => "email.send", "status" => "pending", "previous_attempts" => 3 }, uc(:retry_job).call(@actor, id))
    audit = owner_query("SELECT actor_type, details FROM audit_events WHERE action = 'job.retried' AND resource_id = $1", [id]).first

    assert_equal ["user", { "kind" => "email.send", "attempts" => 3, "last_error" => nil }], [audit["actor_type"], JSON.parse(audit["details"])]
    attendant = A::Actor.user(user_id: @org[:user_id], organization_id: @org[:organization_id], role: "owner")
    owner_query("UPDATE memberships SET role = 'attendant' WHERE user_id = $1", [@org[:user_id]])

    assert_raises(D::AccessDenied, "papel recarregado do banco") { uc(:retry_job).call(attendant, redacted) }
    assert_raises(D::AccessDenied) { uc(:list_failed_jobs).call(attendant) }
  end
end
