# frozen_string_literal: true

require_relative "../unit_helper"

# Regras das configurações da organização (política de cancelamento, validade padrão do bloqueio, fuso e
# nome), da revisão e da desativação de filiais.
class OrganizationSettingsTest < UnitTest
  O = Domain::Organizations
  P = O::CancellationPolicy
  FIELD = "faixas_cancelamento"
  DEFAULT_ROWS = [%w[72 0], %w[24 30], %w[0 100]].freeze

  def tier(hours, bps) = { "min_hours_before" => hours, "fee_bps" => bps }
  def policy(*pairs) = { "tiers" => pairs.map { |hours, bps| tier(hours, bps) } }
  def messages(field = FIELD, &) = assert_raises(Domain::ValidationError, &).errors.fetch(field)

  def organization(settings: {}, timezone: "America/Sao_Paulo")
    O::Organization.new(id: "o1", name: "Locadora Alfa", slug: "locadora-alfa", timezone: timezone, status: "active", settings: settings)
  end

  def revise(org = organization, **attrs)
    org.revise(name: "Locadora Alfa", timezone: org.timezone, hold_minutes: "30", cancellation_rows: DEFAULT_ROWS, **attrs)
  end

  def branch(**attrs)
    O::Branch.new(id: "b1", organization_id: "o1", name: "Matriz", code: "MATRIZ", address: nil, active: true, **attrs)
  end

  # Política de cancelamento ---------------------------------------------------------------------------

  def test_build_accepts_the_default_and_normalizes_the_order
    assert_equal P::DEFAULT, P.build(P::DEFAULT["tiers"])
    assert_equal P::DEFAULT, P.build(P::DEFAULT["tiers"].reverse)
    assert_equal policy([0, 5000]), P.build([tier(0, 5000)])
  end

  def test_build_reports_one_message_per_rule
    assert_equal(["informe ao menos uma faixa"], messages { P.build([]) })
    assert_equal(["informe ao menos uma faixa"], messages { P.build(nil) })
    assert_equal(["no máximo 6 faixas"], messages { P.build((0..6).map { |i| tier(i * 10, 10_000) }) })
    assert_equal(["faixa 1: antecedência deve ser um número inteiro de horas entre 0 e 8760"], messages { P.build([tier(8761, 0), tier(0, 0)]) })
    assert_equal(["faixa 2: multa entre 0% e 100%"], messages { P.build([tier(24, 0), tier(0, 10_001)]) })
    assert_equal(["antecedência repetida: 24 h"], messages { P.build([tier(24, 0), tier(24, 10), tier(0, 100)]) })
    assert_equal(["inclua uma faixa de 0 h (cancelamento com menos antecedência que as demais faixas ou após o início)"],
                 messages { P.build([tier(24, 0)]) })
    assert_equal(["a multa não pode diminuir à medida que o início se aproxima (24 h: 30%; 0 h: 10%)"],
                 messages { P.build([tier(24, 3000), tier(0, 1000)]) })
    assert_equal(["faixa 1: antecedência deve ser um número inteiro de horas entre 0 e 8760", "faixa 1: multa entre 0% e 100%"],
                 messages { P.build([tier(24.5, 1.5), tier(0, 0)]) })
    assert_equal(["faixa 1: antecedência deve ser um número inteiro de horas entre 0 e 8760", "faixa 1: multa entre 0% e 100%"],
                 messages { P.build(["texto", tier(0, 0)]) })
  end

  def test_build_gathers_every_message_with_line_messages_first
    errors = messages { P.build([tier(-1, 0), tier(48, 20_000), tier(24, 5000), tier(24, 5000), tier(12, 1000)]) }

    assert_equal ["faixa 1: antecedência deve ser um número inteiro de horas entre 0 e 8760", "faixa 2: multa entre 0% e 100%",
                  "antecedência repetida: 24 h", "a multa não pode diminuir à medida que o início se aproxima (24 h: 50%; 12 h: 10%)"], errors
  end

  def test_from_form_compacts_rows_and_converts_percentages
    rows = [["", ""], ["48", "12,5"], [" ", " "], ["0", "100"], [nil, nil]]

    assert_equal policy([48, 1250], [0, 10_000]), P.from_form(rows)
    assert_equal [%w[48 12,5], %w[0 100]], P.compact_rows(rows)
    assert_equal(["faixa 2: informe antecedência e multa"], messages { P.from_form([["", ""], %w[24 10], ["0", ""]]) })
    assert_equal(["faixa 1: multa inválida (use até duas casas decimais)"], messages { P.from_form([%w[0 1e2]]) })
    assert_equal(["faixa 1: antecedência deve ser um número inteiro de horas entre 0 e 8760"], messages { P.from_form([["-1", "10"], %w[0 10]]) })
    assert_equal(["faixa 1: antecedência deve ser um número inteiro de horas entre 0 e 8760"], messages { P.from_form([%w[9000 10], %w[0 10]]) })
    assert_equal(["faixa 1: multa entre 0% e 100%"], messages { P.from_form([%w[0 150]]) })
    assert_equal(["informe ao menos uma faixa"], messages { P.from_form([["", ""]]) })
  end

  def test_from_form_refuses_more_than_six_filled_rows_without_converting
    rows = Array.new(7) { |i| ["x#{i}", "?"] } + [["", ""]]

    assert_equal(["no máximo 6 faixas"], messages { P.from_form(rows) })
  end

  def test_line_messages_select_the_messages_of_one_line
    errors = messages { P.from_form([["", ""], ["a", "1"], %w[10 b], %w[0 10]]) }

    assert_equal ["faixa 1: antecedência deve ser um número inteiro de horas entre 0 e 8760"], P.line_messages(errors, 1)
    assert_equal ["faixa 2: multa inválida (use até duas casas decimais)"], P.line_messages(errors, 2)
    assert_empty P.line_messages(errors, 3)
    assert_empty P.line_messages(errors, 11), "o prefixo inclui o separador"
  end

  def test_valid_default_and_canonical
    assert P.valid?(P::DEFAULT)
    refute P.valid?(policy([0, 10_000], [72, 0], [24, 3000])), "fora da ordem canônica"
    refute P.valid?(policy([24, 0]))
    refute P.valid?(nil)
    assert P.default?(policy([0, 10_000], [72, 0], [24, 3000]))
    refute P.default?(policy([0, 10_000]))
    legacy = policy([24, 0])

    assert_same legacy, P.canonical(legacy), "política fora das regras atuais é mantida como está"
  end

  def test_describe_keeps_the_previous_texts_and_covers_the_single_tier
    assert_equal ["72 h ou mais antes do início: multa de 0% do valor contratado",
                  "de 24 h a menos de 72 h antes do início: multa de 30% do valor contratado",
                  "menos de 24 h antes do início (ou após o início): multa de 100% do valor contratado"], P.describe(P::DEFAULT)
    assert_equal P.describe(P::DEFAULT), Domain::Contracts::Cancellation.describe(P::DEFAULT)
    assert_equal ["em qualquer momento (antes ou após o início): multa de 12,5% do valor contratado"], P.describe(policy([0, 1250]))
  end

  def test_ranges_and_examples_use_integer_money
    assert_equal ["72 h ou mais", "de 24 h a menos de 72 h", "menos de 24 h ou após o início"], P.ranges(P::DEFAULT)
    assert_equal ["qualquer antecedência"], P.ranges(policy([0, 5000]))
    examples = P.examples(policy([48, 1250], [0, 3333]))

    assert_equal([["48 h ou mais", 1250, 12_500], ["menos de 48 h ou após o início", 3333, 33_330]],
                 examples.map { |row| [row["range"], row["fee_bps"], row["fee"].cents] })
    assert_instance_of Domain::Money, examples.first["fee"]
    assert_equal 50, P.examples(policy([0, 5000]), base: Domain::Money.new(100)).first["fee"].cents
  end

  # Organização ---------------------------------------------------------------------------------------

  def test_revise_without_changes_returns_the_same_object
    org = organization

    assert_same org, revise(org)
    assert_same org, revise(org, name: "  Locadora   Alfa ", cancellation_rows: DEFAULT_ROWS.reverse + [["", ""]])
  end

  def test_revise_never_stores_default_values_and_preserves_unknown_keys
    org = organization(settings: { "tema" => "escuro" })
    revised = revise(org, hold_minutes: "60", cancellation_rows: [%w[48 10], %w[0 50]])

    assert_equal({ "tema" => "escuro", "hold_minutes" => 60, "cancellation_policy" => policy([48, 1000], [0, 5000]) }, revised.settings)
    assert_equal [2, 60, false, false], [revised.lock_version, revised.hold_minutes, revised.default_hold_minutes?, revised.default_cancellation_policy?]
    restored = revise(revised)

    assert_equal({ "tema" => "escuro" }, restored.settings, "as chaves voltam a ser removidas no padrão")
    assert_equal 3, restored.lock_version
    assert_equal({ "tema" => "escuro" }, revise(org, name: "Locadora Beta").settings, "valores iguais ao padrão não são gravados")
  end

  def test_renaming_keeps_the_defaults
    renamed = revise(organization(settings: { "hold_minutes" => 30, "cancellation_policy" => P::DEFAULT }), name: "Locadora Beta")

    assert_equal ["Locadora Beta", true, true], [renamed.name, renamed.default_hold_minutes?, renamed.default_cancellation_policy?]
    assert_empty renamed.settings
  end

  def test_timezone_change_requires_confirmation
    org = organization

    assert_equal ["confirme a troca do fuso horário depois de ler as consequências"],
                 messages("confirmar_fuso") { revise(org, timezone: "America/Manaus") }
    changed = revise(org, timezone: "America/Manaus", confirm_timezone_change: true)

    assert_equal ["America/Manaus", true], [changed.timezone, org.timezone_changed?(changed)]
    refute org.timezone_changed?(revise(org, name: "Locadora Beta"))
  end

  def test_current_timezone_is_accepted_outside_the_list_and_other_zones_are_not
    europe = organization(timezone: "Europe/Lisbon")

    assert_same europe, revise(europe)
    assert_equal ["escolha um fuso horário da lista"], messages("fuso_horario") { revise(europe, timezone: "Europe/Madrid", confirm_timezone_change: true) }
    assert_equal ["obrigatório"], messages("fuso_horario") { revise(timezone: " ") }
    assert_equal "Europe/Lisbon", O::Settings.zone_label("Europe/Lisbon")
    assert_equal "Manaus (leste do AM)", O::Settings.zone_label("America/Manaus")
    assert_equal 16, O::Settings::TIME_ZONES.size
  end

  def test_hold_minutes_limits
    assert_equal [5, 1440], [revise(hold_minutes: "5").hold_minutes, revise(hold_minutes: 1440).hold_minutes]
    assert_equal ["entre 5 e 1440 minutos"], messages("validade_bloqueio") { revise(hold_minutes: "4") }
    assert_equal ["entre 5 e 1440 minutos"], messages("validade_bloqueio") { revise(hold_minutes: "1441") }
    assert_equal ["número inteiro de minutos"], messages("validade_bloqueio") { revise(hold_minutes: "abc") }
    assert_equal 45, organization(settings: { "hold_minutes" => "45" }).hold_minutes
  end

  def test_changes_report_effective_values
    org = organization(settings: { "hold_minutes" => 30 })
    revised = revise(org, name: "Locadora Beta", hold_minutes: "60", cancellation_rows: [%w[0 50]], timezone: "America/Manaus",
                          confirm_timezone_change: true)

    assert_equal({ "name" => ["Locadora Alfa", "Locadora Beta"], "timezone" => ["America/Sao_Paulo", "America/Manaus"],
                   "hold_minutes" => [30, 60], "cancellation_policy" => [P::DEFAULT, policy([0, 5000])] }, org.changes(revised))
    assert_equal({ "hold_minutes" => [60, 30] }, revised.changes(revised.with(settings: revised.settings.except("hold_minutes"))))
  end

  def test_revise_gathers_errors_of_every_field
    errors = assert_raises(Domain::ValidationError) do
      organization.revise(name: "A", timezone: "Marte/Base", hold_minutes: "0", cancellation_rows: [%w[24 10]])
    end.errors

    assert_equal %w[nome fuso_horario validade_bloqueio faixas_cancelamento], errors.keys
    assert_equal ["deve ter entre 2 e 120 caracteres"], errors["nome"]
  end

  # Filiais -------------------------------------------------------------------------------------------

  def test_branch_revision_and_changes
    original = branch
    revised = original.revise(name: "Sede", address: "Rua A, 10")

    assert_same original, original.revise(name: " Matriz ", address: " ")
    assert_equal ["Sede", "Rua A, 10", 2], [revised.name, revised.address, revised.lock_version]
    assert_equal({ "name" => %w[Matriz Sede], "address" => [nil, "Rua A, 10"] }, original.changes(revised))
    assert_equal({ "nome" => ["obrigatório"], "endereco" => ["até 300 caracteres"] },
                 assert_raises(Domain::ValidationError) { original.revise(name: "", address: "x" * 301) }.errors)
  end

  def test_branch_build_refuses_long_addresses_instead_of_truncating
    errors = assert_raises(Domain::ValidationError) { O::Branch.build(id: "b2", organization_id: "o1", name: "N", code: "x y", address: "x" * 301) }.errors

    assert_equal %w[codigo nome endereco], errors.keys
    built = O::Branch.build(id: "b2", organization_id: "o1", name: "Norte", code: " norte ", address: "x" * 300)

    assert_equal ["NORTE", 300, true, nil, 1], [built.code, built.address.length, built.active, built.deactivated_at, built.lock_version]
  end

  def test_branch_deactivation_and_reactivation
    now = Time.utc(2026, 3, 2, 12)
    inactive = branch.deactivate(now)

    assert_equal [false, now, 2, "inactive", "Matriz (inativa)"], [inactive.active, inactive.deactivated_at, inactive.lock_version, inactive.status,
                                                                   inactive.label_with_status]
    assert_same inactive, inactive.deactivate(now + 60)
    active = inactive.reactivate

    assert_equal [true, nil, 3, "active", "Matriz"], [active.active, active.deactivated_at, active.lock_version, active.status, active.label_with_status]
    assert_same active, active.reactivate
    assert_equal({ "active" => "Ativa", "inactive" => "Inativa" }, O::BRANCH_STATUSES)
  end

  def none = { count: 0, codes: [] }

  def test_deactivation_blockers_by_kind_with_plurals
    assert_nil O::Branch.deactivation_blockers("NORTE", { reservations: none, sent_quotes: none, approved_quotes: none, incoming_transfers: none })
    message = O::Branch.deactivation_blockers("CODIGO", { reservations: { count: 2, codes: %w[R-000012 R-000015] },
                                                          sent_quotes: { count: 1, codes: %w[Q-000003] },
                                                          approved_quotes: { count: 1, codes: %w[Q-000004] },
                                                          incoming_transfers: { count: 1, codes: %w[TR-000002] } })

    assert_equal "Não é possível desativar a filial CODIGO: 2 reservas em aberto (R-000012, R-000015): conclua ou cancele; " \
                 "1 orçamento enviado (Q-000003): aguarde a decisão, registre a recusa ou crie nova versão em outra filial; " \
                 "1 orçamento aprovado (Q-000004): converta em reserva e conclua ou cancele a reserva; " \
                 "1 transferência pendente com destino à filial (TR-000002): registre o recebimento ou cancele.", message
  end

  def test_deactivation_blockers_show_five_codes_and_the_rest
    codes = (1..5).map { |i| format("R-%06d", i) }
    plural = O::Branch.deactivation_blockers("MATRIZ", { reservations: { count: 1, codes: ["R-000001"] },
                                                         sent_quotes: { count: 2, codes: %w[Q-1 Q-2] }, approved_quotes: { count: 3, codes: %w[Q-3 Q-4 Q-5] },
                                                         incoming_transfers: { count: 2, codes: %w[TR-1 TR-2] } })

    assert_includes plural, "1 reserva em aberto (R-000001)"
    assert_includes plural, "2 orçamentos enviados (Q-1, Q-2)"
    assert_includes plural, "3 orçamentos aprovados (Q-3, Q-4, Q-5): converta em reservas e conclua ou cancele as reservas"
    assert_includes plural, "2 transferências pendentes com destino à filial (TR-1, TR-2)"
    assert_equal "Não é possível desativar a filial MATRIZ: 8 reservas em aberto (#{codes.join(", ")} e mais 3): conclua ou cancele.",
                 O::Branch.deactivation_blockers("MATRIZ", { reservations: { count: 8, codes: codes } })
  end

  # Outros ---------------------------------------------------------------------------------------------

  def test_time_zone_snapshot_or_fallback
    fallback = Domain::TimeZone.new("America/Manaus")

    assert_equal "America/Sao_Paulo", Domain::TimeZone.snapshot_or("America/Sao_Paulo", fallback).identifier
    assert_same fallback, Domain::TimeZone.snapshot_or(nil, fallback)
    assert_same fallback, Domain::TimeZone.snapshot_or("", fallback)
  end

  def test_version_fingerprint_changes_with_the_policy
    attrs = { id: "v1", quote_id: "q1", number: 1, branch_id: "b1", period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"),
              valid_until: Time.utc(2026, 3, 9), items: [], pricing: {}, terms: nil, manual_discount_bps: 0, deposit: Domain::Money.zero,
              total: Domain::Money.zero, created_at: Time.utc(2026, 3, 2), sent_at: nil }
    version = Domain::Quotes::Version.new(**attrs, cancellation_policy: P::DEFAULT)

    assert_nil Domain::Quotes::Version.new(**attrs).cancellation_policy
    refute_equal version.fingerprint, version.with(cancellation_policy: policy([0, 5000])).fingerprint
    assert_equal version.fingerprint, version.with(id: "v2", number: 2).fingerprint
  end

  def test_contract_time_zone_identifier_comes_from_the_period
    contract = Domain::Contracts::Contract.new(id: "c1", organization_id: "o1", code: "C-1", reservation_id: "r1", customer_id: "c1", quote_id: nil,
                                               status: "issued", terms: { "period" => { "timezone" => "America/Manaus" } },
                                               current_document_version: 1, issued_at: nil, activated_at: nil, closed_at: nil, cancelled_at: nil,
                                               cancellation_reason: nil, cancellation_fee_cents: nil, lock_version: 1)

    assert_equal "America/Manaus", contract.time_zone_identifier
    assert_nil contract.with(terms: {}).time_zone_identifier
  end
end
