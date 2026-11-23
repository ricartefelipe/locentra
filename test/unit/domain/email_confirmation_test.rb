# frozen_string_literal: true

require_relative "../unit_helper"

# Prazo de confirmação de e-mail (ADR-031): 7 dias inteiros contados da criação do usuário, com limites
# exatos no segundo e sem aritmética de ponto flutuante; ações bloqueadas até a confirmação e conta
# somente leitura depois do prazo.
class EmailConfirmationDomainTest < UnitTest
  EC = Domain::Identity::EmailConfirmation
  CREATED_AT = Time.utc(2026, 3, 2, 12, 0, 0)

  def standing(now, confirmed_at: nil, created_at: CREATED_AT) = EC.standing(confirmed_at: confirmed_at, created_at: created_at, now: now)

  def test_grace_period_is_an_integer_constant_of_seven_days
    assert_equal 7, EC::GRACE_PERIOD_DAYS
    assert_equal 604_800, EC::GRACE_PERIOD_SECONDS
    assert_kind_of Integer, EC::GRACE_PERIOD_SECONDS
    assert_equal Time.utc(2026, 3, 9, 12, 0, 0), EC.deadline(CREATED_AT)
  end

  def test_unconfirmed_account_is_pending_until_the_last_second_and_read_only_at_the_deadline
    deadline = Time.utc(2026, 3, 9, 12, 0, 0)
    last_second = standing(deadline - 1)

    assert_equal [EC::PENDING, 1, 1, deadline], [last_second.status, last_second.remaining_seconds, last_second.remaining_days, last_second.deadline]
    refute_predicate last_second, :read_only?
    at_deadline = standing(deadline)

    assert_equal [EC::READ_ONLY, 0, deadline], [at_deadline.status, at_deadline.remaining_seconds, at_deadline.deadline]
    assert_predicate at_deadline, :read_only?
    assert_equal EC::READ_ONLY, standing(deadline + (30 * 86_400)).status
  end

  def test_remaining_time_is_rounded_up_to_whole_seconds_and_days
    fresh = standing(CREATED_AT)

    assert_equal [604_800, 7], [fresh.remaining_seconds, fresh.remaining_days]
    assert_kind_of Integer, fresh.remaining_seconds
    assert_equal 7, standing(CREATED_AT + 1).remaining_days, "6 dias e 23 h ainda são 7 dias começados"
    assert_equal 6, standing(CREATED_AT + 86_400).remaining_days
    fractional = standing(Time.at(Rational((CREATED_AT.to_i * 10) + 5, 10)).utc)

    assert_equal 604_800, fractional.remaining_seconds, "fração de segundo arredondada para cima"
  end

  def test_fractional_creation_instant_is_compared_exactly
    created_at = Time.at(Rational((CREATED_AT.to_i * 1_000_000) + 250_000, 1_000_000)).utc
    deadline = created_at + EC::GRACE_PERIOD_SECONDS

    assert_equal EC::PENDING, standing(Time.at(deadline.to_r - Rational(1, 1_000_000)).utc, created_at: created_at).status
    assert_equal EC::READ_ONLY, standing(deadline, created_at: created_at).status
  end

  def test_confirmed_account_has_no_deadline
    confirmed = standing(CREATED_AT + (365 * 86_400), confirmed_at: CREATED_AT + 60)

    assert_predicate confirmed, :confirmed?
    assert_equal [EC::CONFIRMED, nil, nil, 0], [confirmed.status, confirmed.deadline, confirmed.remaining_seconds, confirmed.remaining_days]
    assert_equal EC::CONFIRMED, EC.status(confirmed_at: CREATED_AT, created_at: CREATED_AT, now: CREATED_AT)
  end

  def test_missing_creation_instant_is_a_programming_error
    assert_raises(ArgumentError) { EC.standing(confirmed_at: nil, created_at: nil, now: CREATED_AT) }
  end

  def test_outbound_actions_require_confirmation
    assert_equal EC::CONFIRMED, EC.outbound!(EC::CONFIRMED, "members.invite")
    [EC::PENDING, EC::READ_ONLY, nil].each do |status|
      error = assert_raises(Domain::EmailUnconfirmed) { EC.outbound!(status, "quotes.send") }

      assert_equal "Confirme seu e-mail para enviar orçamentos aos clientes: abra o link enviado ao seu e-mail ou peça o reenvio da confirmação.",
                   error.message
      assert_equal ["email_unconfirmed", :outbound], [error.code, error.reason]
      assert_kind_of Domain::AccessDenied, error
    end
    assert_raises(ArgumentError) { EC.outbound!(EC::CONFIRMED, "acao.inexistente") }
  end

  def test_every_outbound_action_has_a_message
    EC::OUTBOUND_ACTIONS.each do |action, label|
      error = assert_raises(Domain::EmailUnconfirmed) { EC.outbound!(EC::PENDING, action) }

      assert_includes error.message, "Confirme seu e-mail para #{label}:"
    end
    assert_equal 10, EC::OUTBOUND_ACTIONS.size
  end

  def test_read_only_refuses_mutations_only_after_the_deadline
    assert_equal EC::PENDING, EC.writable!(EC::PENDING)
    assert_equal EC::CONFIRMED, EC.writable!(EC::CONFIRMED)
    assert_nil EC.writable!(nil)
    error = assert_raises(Domain::EmailUnconfirmed) { EC.writable!(EC::READ_ONLY) }

    assert_equal :read_only, error.reason
    assert_match(/\AConta somente leitura até a confirmação do e-mail/, error.message)
  end

  # A correção do próprio e-mail vale somente para a conta não confirmada (pendente ou somente leitura).
  def test_only_an_unconfirmed_email_can_be_corrected
    assert_nil EC.correctable!(nil)
    error = assert_raises(Domain::AccessDenied) { EC.correctable!(CREATED_AT) }

    assert_equal "O e-mail já está confirmado: a correção vale somente para conta não confirmada.", error.message
  end

  def test_email_mask_keeps_only_the_first_character_and_the_domain
    email = Domain::Identity::Email

    assert_equal "d***@alfa.test", email.mask("dona@alfa.test")
    assert_equal "a***@b.test", email.mask("a@b.test")
    assert_nil email.mask(nil)
  end

  def test_read_permissions_are_the_query_permissions_of_the_matrix
    identity = Domain::Identity

    assert(identity::READ_PERMISSIONS.all? { |permission| permission.end_with?(".read") })
    refute identity.mutation?("customers.read")
    assert identity.mutation?("customers.write")
    assert identity.mutation?("integrations.manage")
    refute identity.mutation?("portal.access"), "permissão fora da matriz"
    assert_equal(identity::PERMISSIONS.keys.reject { |permission| identity::READ_PERMISSIONS.include?(permission) },
                 identity::PERMISSIONS.keys.select { |permission| identity.mutation?(permission) })
  end
end
