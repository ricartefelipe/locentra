# frozen_string_literal: true

require_relative "api_v1_helper"
require_relative "../support/portal_support"

# Alteração das configurações pela API v1 (Rack::Lint), somente por sessão de usuário com
# `organization.manage` e X-CSRF-Token: PATCH parcial com versão obrigatória, política em pontos-base com as
# mensagens da interface, confirmação da troca de fuso, chaves desconhecidas recusadas, idempotência,
# auditoria com o canal e recusa de gerentes e credenciais (ADR-029).
class OrganizationSettingsApiTest < ApiV1TestCase
  include PortalHelpers

  PATH = "/api/v1/organization/settings"
  POLICY = "faixas_cancelamento"

  def setup
    super
    sign_in("dona@alfa.test")
  end

  def sign_in(email, password = "senha-muito-segura-1")
    post "/sair", { "_csrf" => @csrf } if @csrf
    login(email, password)
    @csrf = csrf
  end

  def settings_patch!(status, body, key: next_key, csrf_token: @csrf, extra: {})
    env = { "CONTENT_TYPE" => "application/json" }.merge(extra)
    env["HTTP_IDEMPOTENCY_KEY"] = key if key
    env["HTTP_X_CSRF_TOKEN"] = csrf_token if csrf_token
    patch PATH, JSON.generate(body), env
    checked(status, "PATCH #{PATH} #{body.inspect}")
  end

  def tier(hours, bps) = { "min_hours_before" => hours, "fee_bps" => bps }

  def current(org = @org)
    owner_query("SELECT name, timezone, lock_version, settings FROM organizations WHERE id = $1", [org[:organization_id]],
                tenant: org[:organization_id]).first
  end

  def policy_messages(tiers)
    settings_patch!(422, { "cancellation_policy" => { "tiers" => tiers }, "lock_version" => current["lock_version"].to_i })

    assert_equal [POLICY], fields.keys
    fields[POLICY]
  end

  def test_partial_update_changes_only_the_informed_field_and_audits_the_channel
    body = settings_patch!(200, { "hold_minutes" => 45, "lock_version" => 1 })

    assert_conforms body, "OrganizationSettingsResult"
    assert_equal [true, 45, 2, "Locadora Alfa", "America/Sao_Paulo"],
                 [body["changed"], body.dig("organization", "settings", "hold_minutes"), body.dig("organization", "lock_version"),
                  body.dig("organization", "name"), body.dig("organization", "time_zone")]
    assert_equal D::Organizations::CancellationPolicy::DEFAULT, body.dig("organization", "settings", "cancellation_policy")
    assert_equal [{ "changes" => { "hold_minutes" => [30, 45] }, "lock_version" => 2, "via" => "api" }], audit_details("organization.settings_updated")
    event = owner_query("SELECT actor_type, actor_id FROM audit_events WHERE action = 'organization.settings_updated'").first

    assert_equal ["user", @org[:user_id]], event.values_at("actor_type", "actor_id")
    assert_equal 2, current["lock_version"].to_i
  end

  # Política gravada antes das regras atuais (a 0016 só confere o formato): o PATCH sem
  # `cancellation_policy` a mantém como está, sem revalidá-la.
  def test_partial_update_keeps_a_stored_policy_outside_the_current_rules
    legacy = { "tiers" => [tier(24, 3000), tier(0, 1000)] }
    owner_query("UPDATE organizations SET settings = jsonb_set(settings, '{cancellation_policy}', $2::jsonb) WHERE id = $1",
                [@org[:organization_id], JSON.generate(legacy)], tenant: @org[:organization_id])
    body = settings_patch!(200, { "hold_minutes" => 45, "lock_version" => 1 })

    assert_equal [true, 45, legacy], [body["changed"], body.dig("organization", "settings", "hold_minutes"),
                                      body.dig("organization", "settings", "cancellation_policy")]
    assert_equal [{ "changes" => { "hold_minutes" => [30, 45] }, "lock_version" => 2, "via" => "api" }], audit_details("organization.settings_updated")
    assert_equal legacy, JSON.parse(current["settings"])["cancellation_policy"]
  end

  def test_unchanged_values_answer_changed_false_without_audit
    body = settings_patch!(200, { "hold_minutes" => 30, "name" => "Locadora Alfa", "lock_version" => 1 })

    assert_conforms body, "OrganizationSettingsResult"
    assert_equal [false, 1], [body["changed"], body.dig("organization", "lock_version")]
    assert_equal 0, audit_count("organization.settings_updated")
  end

  def test_policy_in_basis_points_with_the_rules_and_messages_of_the_interface
    body = settings_patch!(200, { "cancellation_policy" => { "tiers" => [tier(0, 5000), tier(48, 1000)] }, "lock_version" => 1 })

    assert_equal({ "tiers" => [tier(48, 1000), tier(0, 5000)] }, body.dig("organization", "settings", "cancellation_policy"))
    assert_equal ["48 h ou mais antes do início: multa de 10% do valor contratado",
                  "menos de 48 h antes do início (ou após o início): multa de 50% do valor contratado"],
                 body.dig("organization", "settings", "cancellation_terms")
    hours = "antecedência deve ser um número inteiro de horas entre 0 e 8760"

    assert_equal ["faixa 1: #{hours}"], policy_messages([tier("48", 0), tier(0, 0)])
    assert_equal ["faixa 2: multa entre 0% e 100%"], policy_messages([tier(48, 0), tier(0, 12.5)])
    assert_equal ["no máximo 6 faixas"], policy_messages((0..6).map { |i| tier(i * 10, 10_000) })
    assert_equal ["inclua uma faixa de 0 h (cancelamento com menos antecedência que as demais faixas ou após o início)"],
                 policy_messages([tier(24, 0)])
    assert_equal ["a multa não pode diminuir à medida que o início se aproxima (24 h: 30%; 0 h: 10%)"], policy_messages([tier(24, 3000), tier(0, 1000)])
    assert_equal ["informe as faixas como uma lista de objetos com min_hours_before e fee_bps"], policy_messages("72:0")
    settings_patch!(422, { "cancellation_policy" => [tier(0, 0)], "lock_version" => 2 })

    assert_match(/somente tiers/, fields[POLICY].first)
    settings_patch!(422, { "cancellation_policy" => { "tiers" => [tier(0, 0)], "default" => true }, "lock_version" => 2 })

    assert_error "validation_error"
    assert_equal 1, audit_count("organization.settings_updated")
  end

  def test_time_zone_change_requires_confirmation
    settings_patch!(422, { "time_zone" => "America/Manaus", "lock_version" => 1 })

    assert_equal({ "confirmar_fuso" => ["confirme a troca do fuso horário depois de ler as consequências"] }, fields)
    settings_patch!(422, { "time_zone" => "America/Manaus", "confirm_time_zone_change" => "sim", "lock_version" => 1 })

    assert_equal({ "confirmar_fuso" => ["informe true ou false"] }, fields)
    settings_patch!(422, { "time_zone" => "Europe/Lisbon", "confirm_time_zone_change" => true, "lock_version" => 1 })

    assert_equal({ "fuso_horario" => ["escolha um fuso horário da lista"] }, fields)
    body = settings_patch!(200, { "time_zone" => "America/Manaus", "confirm_time_zone_change" => true, "lock_version" => 1 })

    assert_equal ["America/Manaus", "Manaus (leste do AM)"], body["organization"].values_at("time_zone", "time_zone_label")
    assert_equal [{ "changes" => { "timezone" => ["America/Sao_Paulo", "America/Manaus"] }, "lock_version" => 2, "timezone_confirmed" => true,
                    "via" => "api" }], audit_details("organization.settings_updated")
  end

  def test_lock_version_is_required_and_must_be_current
    settings_patch!(422, { "hold_minutes" => 45 })

    assert_equal({ "lock_version" => ["informe um número inteiro"] }, fields)
    settings_patch!(422, { "hold_minutes" => 45, "lock_version" => 0 })

    assert_equal({ "lock_version" => ["mínimo 1"] }, fields)
    settings_patch!(409, { "hold_minutes" => 45, "lock_version" => 5 })

    assert_error "stale_organization"

    assert_equal [Locentra::Application::Organizations::STALE_ORGANIZATION, 1, 0],
                 [error_message, current["lock_version"].to_i, audit_count("organization.settings_updated")]
  end

  def test_unknown_or_read_only_keys_and_format_errors_are_refused_by_name
    settings_patch!(422, { "slug" => "outra", "settings" => {}, "branches" => [], "hold_minutes" => "45", "name" => 7, "lock_version" => 1 })

    assert_equal({ "slug" => ["campo desconhecido ou não editável"], "settings" => ["campo desconhecido ou não editável"],
                   "branches" => ["campo desconhecido ou não editável"], "validade_bloqueio" => ["informe um número inteiro"],
                   "nome" => ["informe um texto"] }, fields)
    settings_patch!(422, { "hold_minutes" => 4, "lock_version" => 1 })

    assert_equal({ "validade_bloqueio" => ["entre 5 e 1440 minutos"] }, fields)
    assert_equal 1, current["lock_version"].to_i
  end

  def test_csrf_and_idempotency_key_are_required_and_replays_are_recognized
    settings_patch!(403, { "hold_minutes" => 45, "lock_version" => 1 }, csrf_token: nil)

    assert_error "csrf"
    settings_patch!(403, { "hold_minutes" => 45, "lock_version" => 1 }, csrf_token: "token-de-outra-sessao")

    assert_error "csrf"
    settings_patch!(422, { "hold_minutes" => 45, "lock_version" => 1 }, key: nil)

    assert_equal ["Idempotency-Key"], fields.keys
    key = next_key
    first = settings_patch!(200, { "hold_minutes" => 45, "lock_version" => 1 }, key: key)

    assert_equal first, settings_patch!(200, { "hold_minutes" => 45, "lock_version" => 1 }, key: key)
    assert_predicate self, :replayed?
    settings_patch!(409, { "hold_minutes" => 50, "lock_version" => 2 }, key: key)

    assert_error "idempotency_key_reused"
    assert_equal [2, 1], [current["lock_version"].to_i, audit_count("organization.settings_updated")]
  end

  def test_manager_session_and_credentials_are_refused
    staff_member(@org, "gerente@alfa.test", "manager")
    sign_in("gerente@alfa.test", "senha-muito-segura-7")
    settings_patch!(403, { "hold_minutes" => 45, "lock_version" => 1 })

    assert_equal ["forbidden", "permissão necessária: organization.manage"], [error_code, error_message]
    { %w[organization.read] => "permissão necessária: organization.manage",
      %w[organization.manage organization.read] => "as configurações da organização são alteradas somente por usuários" }.each do |scopes, message|
      patch PATH, JSON.generate("hold_minutes" => 45, "lock_version" => 1), headers(token(scopes), next_key)

      assert_equal [403, "forbidden", message], [last_response.status, error_code, error_message]
      assert_conforms json_body, "Error"
    end
    assert_equal [1, 0], [current["lock_version"].to_i, audit_count("organization.settings_updated")]
  end

  def test_beta_session_changes_only_beta
    sign_in("dona@beta.test")
    body = settings_patch!(200, { "name" => "Locadora Beta Eventos", "lock_version" => 1 })

    assert_equal [@beta[:organization_id], "Locadora Beta Eventos"], body["organization"].values_at("id", "name")
    assert_equal([["Locadora Alfa", 1], ["Locadora Beta Eventos", 2]],
                 [current, current(@beta)].map { |row| [row["name"], row["lock_version"].to_i] })
    assert_equal [0, 1], [audit_count("organization.settings_updated"), audit_count("organization.settings_updated", org: @beta)]
  end
end
