# frozen_string_literal: true

# Atalhos dos testes de configurações da organização: alteração das configurações a partir dos valores
# atuais (somente os campos informados mudam), linhas de formulário da política e ator do portal.
module OrganizationSettingsSupport
  def policy_rows(policy)
    policy.fetch("tiers").map { |tier| [tier.fetch("min_hours_before").to_s, Locentra::Domain::Percent.value(tier.fetch("fee_bps"))] }
  end

  def settings_attrs(org, name: nil, timezone: nil, hold_minutes: nil, cancellation_rows: nil, confirm_timezone_change: false)
    { name: name || org.name, timezone: timezone || org.timezone, hold_minutes: hold_minutes || org.hold_minutes.to_s,
      cancellation_rows: cancellation_rows || policy_rows(org.cancellation_policy), confirm_timezone_change: confirm_timezone_change }
  end

  # Alteração pelo caso de uso (somente os campos informados mudam); devolve a organização revisada.
  def change_settings(actor: @actor, lock_version: nil, **changes)
    org = uc(:get_organization).call(actor)[:organization]
    uc(:update_organization_settings).call(actor, settings_attrs(org, **changes), lock_version: lock_version).record
  end

  def current_organization(actor = @actor) = uc(:get_organization).call(actor)[:organization]

  def portal_actor(customer, org: @org)
    user_id = SecureRandom.uuid
    owner_query("INSERT INTO users (id, email, name, password_digest, created_at, updated_at) VALUES ($1, $2, 'Cliente Portal', 'x', now(), now())",
                [user_id, "portal-#{user_id[0, 8]}@example.test"], tenant: org[:organization_id])
    owner_query("INSERT INTO portal_accesses (id, organization_id, user_id, customer_id, created_at) VALUES ($1, $2, $3, $4, now())",
                [SecureRandom.uuid, org[:organization_id], user_id, customer.id], tenant: org[:organization_id])
    Locentra::Application::Actor.customer(user_id: user_id, organization_id: org[:organization_id], customer_id: customer.id, ip: "203.0.113.10")
  end
end
