# frozen_string_literal: true

# Cenário do portal do cliente: contato com e-mail, convite entregue pelo worker (FakeMailer) e aceite.
# Requer WorkerHelpers (drain e @mailer).
module PortalHelpers
  PORTAL_PASSWORD = "senha-do-portal-123"

  def portal_contact(actor, customer, email:, name: "Contato Portal")
    uc(:add_contact).call(actor, customer.id, { name: name, email: email, role: "Compras" })
  end

  # Convite enviado e entregue; devolve o token extraído do e-mail.
  def invite_and_deliver(actor, customer, contact)
    worker_system
    uc(:invite_portal_contact).call(actor, customer_id: customer.id, contact_id: contact.id)
    drain
    portal_token_for(contact.email)
  end

  def portal_token_for(email)
    index = @mailer.deliveries.rindex { |mail| mail[:to] == email && mail[:subject].include?("portal do cliente") }
    raise "e-mail de convite do portal não enviado para #{email}" unless index

    @mailer.token_in(index)
  end

  # Acesso concedido e aceito com conta nova. Devolve o ator `customer` correspondente.
  def portal_customer(actor, customer, email:, name: "Contato Portal")
    token = invite_and_deliver(actor, customer, portal_contact(actor, customer, email: email, name: name))
    result = uc(:accept_portal_invitation).call(token: token, name: name, password: PORTAL_PASSWORD)
    Locentra::Application::Actor.customer(user_id: result[:user_id], organization_id: result[:organization_id],
                                          customer_id: result[:customer_id], ip: "203.0.113.20")
  end

  # Membro da equipe com o papel informado (convite aceito diretamente com token conhecido).
  def staff_member(org, email, role)
    invitation = uc(:invite_member).call(org[:actor], email: email, role: role)
    token = "#{org[:organization_id]}.segredo-#{invitation["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [Locentra::Application::Identity::Tokens.digest(token), invitation["id"]],
                tenant: org[:organization_id])
    joined = uc(:accept_invitation).call(token: token, name: "Membro #{role}", password: "senha-muito-segura-7")
    Locentra::Application::Actor.user(user_id: joined[:user_id], organization_id: org[:organization_id], role: role)
  end

  # Contrato emitido para uma reserva confirmada do cliente (documento PDF versão 1).
  def contract_for(actor, customer, branch, product, day)
    reservation = reserve(actor, customer, branch, period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1)),
                          [line(product, 1)], mode: "confirm")
    uc(:issue_contract).call(actor, reservation.id)
  end

  # Orçamento enviado ao cliente (versão 1, sem bloqueio).
  def sent_quote(actor, customer, branch, product, day)
    quote = uc(:create_quote).call(actor, { customer_id: customer.id, branch_id: branch.id, lines: [line(product, 1)],
                                            period: period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1)),
                                            valid_until: t("2026-03-06T12:00:00Z") })
    uc(:send_quote).call(actor, quote.id)
  end
end
