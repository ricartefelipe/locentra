# frozen_string_literal: true

require_relative "integration_helper"

class IdentityFlowTest < DatabaseTest
  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
  end

  def sessions = @system.services[:sessions]

  def issue_token(user_id, purpose)
    @system.transactor.call { |tx| @system.services[:tokens].issue(tx, user_id, purpose, 3600) }
  end

  def test_signup_enqueues_confirmation_and_rejects_duplicates
    jobs = owner_query("SELECT kind, payload FROM jobs WHERE kind = 'email.confirmation'", [], tenant: @org[:organization_id])

    assert_equal([@org[:user_id]], jobs.map { |j| JSON.parse(j["payload"])["user_id"] })
    error = assert_raises(D::Conflict) do
      uc(:sign_up).call(name: "Outra", email: "dona@alfa.test", password: "senha-muito-segura-1", organization_name: "Outra Empresa")
    end
    assert_equal "email_taken", error.code
    homonym = uc(:sign_up).call(name: "Outra", email: "nova@alfa.test", password: "senha-muito-segura-1", organization_name: "Locadora Alfa")
    name, slug = owner_query("SELECT name, slug FROM organizations", [], tenant: homonym[:organization_id]).first.values_at("name", "slug")

    refute_equal @org[:organization_id], homonym[:organization_id]
    assert_equal "Locadora Alfa", name, "nome repetido não revela a outra organização"
    assert_match(/\Alocadora-alfa-[0-9a-f]{6}\z/, slug)
    assert_raises(D::ValidationError) { uc(:sign_up).call(name: "X", email: "x@y.test", password: "curta", organization_name: "Empresa X") }
    assert_raises(D::ValidationError) { uc(:sign_up).call(name: "X", email: "x@y.test", password: "senha-muito-segura-1", organization_name: "Empresa X", plan_id: "ouro") }
  end

  def test_authentication_lockout_after_repeated_failures
    5.times { assert_raises(A::Identity::AuthenticationFailed) { uc(:authenticate).call(email: "dona@alfa.test", password: "errada!", ip: "10.0.0.1") } }
    assert_raises(A::Identity::AuthenticationFailed) { uc(:authenticate).call(email: "dona@alfa.test", password: "senha-muito-segura-1", ip: "10.0.0.2") }
    @clock.advance(16 * 60)

    assert_equal "dona@alfa.test", uc(:authenticate).call(email: "DONA@alfa.test ", password: "senha-muito-segura-1", ip: "10.0.0.3")["email"]
    assert_raises(A::Identity::AuthenticationFailed) { uc(:authenticate).call(email: "ninguem@alfa.test", password: "x" * 12, ip: "10.0.0.4") }
    assert_raises(A::Identity::AuthenticationFailed) { uc(:authenticate).call(email: "dona@alfa.test", password: "ç" * 40, ip: "10.0.0.5") }
  end

  def test_sessions_expire_rotate_and_revoke
    token, row = sessions.create(user_id: @org[:user_id], organization_id: @org[:organization_id], ip: "127.0.0.1", user_agent: "teste")

    assert_equal row["id"], sessions.resolve(token)["id"]
    @clock.advance(90)

    assert_equal @clock.now, sessions.resolve(token)["last_seen_at"]
    new_token, = sessions.rotate(sessions.resolve(token), organization_id: @org[:organization_id])

    assert_nil sessions.resolve(token), "a sessão anterior é revogada na rotação"
    refute_nil sessions.resolve(new_token)
    @clock.advance(3 * 3600)

    assert_nil sessions.resolve(new_token), "expiração por inatividade"
    other, = sessions.create(user_id: @org[:user_id])
    sessions.revoke_all(@org[:user_id], "teste")

    assert_nil sessions.resolve(other)
    assert_nil sessions.resolve("")
    assert_nil sessions.resolve("x" * 300)
  end

  def test_email_confirmation_and_password_reset_are_single_use
    confirm = issue_token(@org[:user_id], "email_confirmation")

    assert_equal @org[:user_id], uc(:confirm_email).call(confirm)
    assert_raises(D::ValidationError) { uc(:confirm_email).call(confirm) }
    assert uc(:request_password_reset).call(email: "dona@alfa.test", ip: "10.1.1.1")
    assert uc(:request_password_reset).call(email: "inexistente@alfa.test", ip: "10.1.1.1")
    jobs = owner_query("SELECT count(*) AS n FROM jobs WHERE kind = 'email.password_reset'", [], tenant: "").first["n"].to_i

    assert_equal 0, jobs, "tarefas sem tenant não são visíveis fora do worker"
    session_token, = sessions.create(user_id: @org[:user_id])
    reset = issue_token(@org[:user_id], "password_reset")
    @clock.advance(30 * 60)
    uc(:reset_password).call(token: reset, password: "nova-senha-segura-123")

    assert_nil sessions.resolve(session_token), "redefinição encerra sessões abertas"
    assert_raises(D::ValidationError) { uc(:reset_password).call(token: reset, password: "outra-senha-segura-9") }
    expired = issue_token(@org[:user_id], "password_reset")
    @clock.advance(3601)

    assert_raises(D::ValidationError) { uc(:reset_password).call(token: expired, password: "outra-senha-segura-9") }
    assert uc(:authenticate).call(email: "dona@alfa.test", password: "nova-senha-segura-123", ip: "10.9.9.9")
  end

  def accept(email, role, **extra)
    invitation = uc(:invite_member).call(@actor, email: email, role: role)
    token = "#{@org[:organization_id]}.segredo-#{invitation["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invitation["id"]])
    [token, uc(:accept_invitation).call(token: token, **extra)]
  end

  def test_invitation_rules
    assert_raises(D::AccessDenied) { uc(:invite_member).call(@actor, email: "x@alfa.test", role: "owner") }
    token, joined = accept("gerente@alfa.test", "manager", name: "Gerente", password: "senha-muito-segura-2")

    assert_raises(D::ValidationError) { uc(:accept_invitation).call(token: token, name: "De novo", password: "senha-muito-segura-2") }
    assert_raises(D::Conflict) { uc(:invite_member).call(@actor, email: "gerente@alfa.test", role: "attendant") }
    manager = A::Actor.user(user_id: joined[:user_id], organization_id: @org[:organization_id], role: "manager")

    assert_raises(D::AccessDenied) { uc(:invite_member).call(manager, email: "y@alfa.test", role: "attendant") }
    assert_raises(D::ValidationError) { uc(:accept_invitation).call(token: "invalido", name: "X", password: "senha-muito-segura-2") }
    other = create_organization(name: "Locadora Gama", email: "gama@example.test")
    invitation = uc(:invite_member).call(other[:actor], email: "dona@alfa.test", role: "auditor")
    cross = "#{other[:organization_id]}.segredo-cruzado"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(cross), invitation["id"]],
                tenant: other[:organization_id])

    assert_raises(D::Conflict) { uc(:accept_invitation).call(token: cross, name: "Dona", password: "senha-muito-segura-1") }
    result = uc(:accept_invitation).call(token: cross, user_id: @org[:user_id])

    assert_equal other[:organization_id], result[:organization_id]
    assert_equal 2, uc(:list_memberships).call(@org[:user_id]).size
    wrong = uc(:invite_member).call(other[:actor], email: "alguem@example.test", role: "auditor")
    wrong_token = "#{other[:organization_id]}.segredo-errado"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(wrong_token), wrong["id"]],
                tenant: other[:organization_id])

    assert_raises(D::AccessDenied) { uc(:accept_invitation).call(token: wrong_token, user_id: @org[:user_id]) }
  end

  def test_role_changes_and_revocation_protect_owner
    _, joined = accept("adm@alfa.test", "admin", name: "Adm", password: "senha-muito-segura-2")
    members = uc(:list_members).call(@actor)[:members]
    admin_membership = members.find { |m| m["user_id"] == joined[:user_id] }
    owner_membership = members.find { |m| m["role"] == "owner" }
    admin = A::Actor.user(user_id: joined[:user_id], organization_id: @org[:organization_id], role: "admin")

    assert_raises(D::AccessDenied) { uc(:revoke_membership).call(admin, membership_id: owner_membership["id"]) }
    assert_raises(D::AccessDenied) { uc(:change_member_role).call(admin, membership_id: owner_membership["id"], role: "auditor") }
    assert_raises(D::ValidationError) { uc(:change_member_role).call(@actor, membership_id: admin_membership["id"], role: "rei") }
    assert_equal "finance", uc(:change_member_role).call(@actor, membership_id: admin_membership["id"], role: "finance")
    uc(:revoke_membership).call(@actor, membership_id: admin_membership["id"])

    assert_raises(D::Conflict) { uc(:revoke_membership).call(@actor, membership_id: admin_membership["id"]) }
    assert_raises(D::NotFound) { uc(:revoke_membership).call(@actor, membership_id: SecureRandom.uuid) }
  end

  def test_plan_limits_are_enforced
    small = create_organization(name: "Locadora Pequena", email: "pequena@example.test", plan: "essencial")
    assert_raises(D::PlanLimitExceeded) { uc(:create_branch).call(small[:actor], name: "Filial 2", code: "F2") }
    assert_raises(D::PlanLimitExceeded) { uc(:create_credential).call(small[:actor], name: "API", scopes: ["customers.read"]) }
    4.times { |i| uc(:invite_member).call(small[:actor], email: "u#{i}@pequena.test", role: "attendant") }

    assert_raises(D::PlanLimitExceeded) { uc(:invite_member).call(small[:actor], email: "u9@pequena.test", role: "attendant") }
    chairs = create_product(small[:actor], sku: "CAD-LIM", tracking: "bulk")

    assert_raises(D::PlanLimitExceeded) { stock(small[:actor], chairs, small[:branch], 301) }
    owner_query("UPDATE subscriptions SET status = 'suspended'", [], tenant: small[:organization_id])

    assert_raises(D::PlanLimitExceeded) { stock(small[:actor], chairs, small[:branch], 1) }
    assert_equal "F2", uc(:create_branch).call(@actor, name: "Filial 2", code: "f2").code
    assert_raises(D::Conflict) { uc(:create_branch).call(@actor, name: "Filial dup", code: "F2") }
  end

  def test_credentials_validation
    assert_raises(D::ValidationError) { uc(:create_credential).call(@actor, name: "X", scopes: [], kind: "api") }
    assert_raises(D::ValidationError) { uc(:create_credential).call(@actor, name: "X", scopes: ["inexistente"]) }
    assert_raises(D::ValidationError) { uc(:create_credential).call(@actor, name: "X", scopes: ["customers.read"], kind: "root") }
    assert_raises(D::ValidationError) { uc(:create_credential).call(@actor, name: "X", scopes: ["customers.read"], expires_in_days: "999") }
    assert_raises(D::ValidationError) { uc(:create_credential).call(@actor, name: "X", scopes: ["customers.read"], expires_in_days: "sempre") }
    row = uc(:create_credential).call(@actor, name: "CLI", scopes: ["jobs.manage"], kind: "cli", expires_in_days: 1)

    assert_equal "cli", uc(:authenticate_credential).call(row["token"]).kind
    @clock.advance(2 * 86_400)

    assert_nil uc(:authenticate_credential).call(row["token"]), "credencial expirada"
    assert_nil uc(:authenticate_credential).call("lcn_#{"0" * 32}_#{"a" * 43}")
    assert_raises(D::NotFound) { uc(:revoke_credential).call(@actor, SecureRandom.uuid) }
  end
end
