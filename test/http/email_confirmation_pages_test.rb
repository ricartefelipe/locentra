# frozen_string_literal: true

require_relative "api_v1_helper"

# Confirmação de e-mail pela interface (Rack::Lint), ADR-031: aviso fixo no layout da equipe com o prazo
# restante e, depois dele, a conta somente leitura; reenvio por POST com CSRF e limites por usuário e por IP;
# mensagens das ações bloqueadas; navegação liberada na conta somente leitura; 403 `email_unconfirmed` na
# API por sessão, conferido contra o OpenAPI.
class EmailConfirmationPagesTest < ApiV1TestCase
  EC = Locentra::Domain::Identity::EmailConfirmation
  NOTICE = "Confirme seu e-mail para liberar convites, credenciais, webhooks, pagamentos e envios a clientes."
  LOCKED = "Conta somente leitura até a confirmação."
  REFUSED = "Conta somente leitura até a confirmação do e-mail"

  def setup
    super
    @gamma = create_organization(name: "Locadora Gama", email: "dona@gama.test", confirmed: false)
    @gamma_actor = @gamma[:actor]
    @gamma_customer = create_customer(@gamma_actor, name: "Cliente Gama")
    @gamma_camera = create_product(@gamma_actor, sku: "CAM-GAMA", tracking: "serialized", pricing: { "daily_cents" => 10_000 })
    register_assets(@gamma_actor, @gamma_camera, @gamma[:branch], 1)
    @gamma_quote = uc(:create_quote).call(@gamma_actor, { customer_id: @gamma_customer.id, branch_id: @gamma[:branch].id,
                                                          period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"),
                                                          lines: [line(@gamma_camera, 1)], valid_until: t("2026-03-08T12:00:00Z") })
    login("dona@gama.test")
  end

  def banner = last_response.body[%r{<div class="email-banner.*?</div>}m]

  def resend(token = csrf, back: "/clientes", env: {})
    post "/confirmar-email/reenviar", { "_csrf" => token, "voltar" => back }, env
  end

  def session_api(path, body = {})
    token = csrf
    post "/api/v1#{path}", JSON.generate(body), { "CONTENT_TYPE" => "application/json", "HTTP_X_CSRF_TOKEN" => token,
                                                  "HTTP_IDEMPOTENCY_KEY" => next_key }
  end

  def refusals = @system.metrics.counter_value("domain_conflicts_total", code: "email_unconfirmed").to_i

  def test_banner_shows_the_remaining_deadline_and_a_resend_form_with_csrf
    get "/clientes"

    assert_equal 200, last_response.status
    assert_includes banner, NOTICE
    assert_includes banner, "restam 7 dias (até 09/03/2026 09:00)"
    assert_includes banner, %(action="/confirmar-email/reenviar")
    assert_includes banner, %(name="_csrf" value="#{csrf}")
    assert_includes banner, %(name="voltar" value="/clientes")
    refute_includes last_response.body, "<script>", "sem script inline (CSP)"
    @clock.advance(EC::GRACE_PERIOD_SECONDS - 3600)
    login("dona@gama.test")
    get "/clientes"

    assert_includes banner, "resta 1 dia (até 09/03/2026 09:00)"
  end

  def test_confirmed_account_has_no_banner
    post "/sair", { "_csrf" => csrf }
    login("dona@alfa.test")

    assert_nil banner
    confirm_email(@gamma[:user_id])
    post "/sair", { "_csrf" => csrf }
    login("dona@gama.test")

    assert_nil banner
  end

  def test_resend_requires_csrf_redirects_back_and_is_limited_per_user
    post "/confirmar-email/reenviar", { "voltar" => "/clientes" }

    assert_equal 403, last_response.status
    resend

    assert_equal 303, last_response.status
    assert_equal "/clientes", last_response.location
    follow_redirect!

    assert_includes last_response.body, "Enviamos um novo link de confirmação para dona@gama.test."
    resend(back: "https://evil.example/")

    assert_equal "/", last_response.location, "retorno somente para caminho local"
    get "/"
    resend

    assert_equal 303, last_response.status
    get "/"
    resend

    assert_equal 429, last_response.status
    assert_operator last_response.headers["retry-after"].to_i, :>, 0
    assert_includes last_response.body, "Muitas tentativas"
  end

  def test_resend_is_limited_per_ip_before_authentication
    limiter = @system.services[:rate_limiter]
    20.times { limiter.hit("email_confirmation:ip:127.0.0.1", limit: 20, window_seconds: 3600) }
    token = csrf
    resend(token)

    assert_equal 429, last_response.status
    resend(token, env: { "REMOTE_ADDR" => "10.20.30.40" })

    assert_equal 303, last_response.status
  end

  def test_confirmed_account_resend_answers_without_sending
    get "/clientes"
    token = csrf
    confirm_email(@gamma[:user_id])
    resend(token)
    follow_redirect!

    assert_includes last_response.body, "Seu e-mail já está confirmado."
    assert_nil banner
  end

  def test_blocked_actions_show_a_clear_message
    post_form "/usuarios/convites", { "email" => "novo@gama.test", "papel" => "attendant" }

    assert_equal 422, last_response.status, "a mensagem volta no próprio formulário"
    assert_includes last_response.body, "Confirme seu e-mail para convidar membros da equipe: abra o link enviado ao seu e-mail ou peça " \
                                        "o reenvio da confirmação."
    get "/usuarios"
    post_form "/credenciais", { "nome" => "ERP", "escopos" => ["customers.read"], "tipo" => "api", "validade" => "30" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Confirme seu e-mail para criar credenciais de API e CLI"
    get "/orcamentos/#{@gamma_quote.id}"
    post_form "/orcamentos/#{@gamma_quote.id}/enviar", {}

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Confirme seu e-mail para enviar orçamentos aos clientes"
    assert_includes banner, NOTICE
    assert_equal 3, refusals
  end

  # A navegação completa da conta somente leitura está em email_confirmation_navigation_test.rb.
  def test_read_only_account_refuses_changes
    @clock.advance(EC::GRACE_PERIOD_SECONDS)
    login("dona@gama.test")

    assert_includes banner, LOCKED
    assert_includes banner, "terminou em 09/03/2026 09:00"
    post_form "/clientes", { "tipo" => "individual", "nome" => "Cliente Novo", "documento" => "39053344705" }

    assert_equal 403, last_response.status
    assert_includes last_response.body, "#{REFUSED}: o prazo de confirmação terminou."
  end

  # Ação para fora recusada volta ao formulário (422); a conta somente leitura vai para a página 403, também nas
  # telas do financeiro e nos formulários que tratam a recusa da ação para fora.
  def test_outbound_refusals_stay_in_the_form_and_read_only_refusals_get_the_error_page
    reservation = reserve(@gamma_actor, @gamma_customer, @gamma[:branch], period("2026-03-12T08:00:00Z", "2026-03-13T08:00:00Z"),
                          [line(@gamma_camera, 1)], mode: "confirm")
    get "/financeiro/provedor"
    post_form "/financeiro/provedor", { "provedor" => "simulator", "nome" => "Simulador" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Confirme seu e-mail para configurar o provedor de pagamentos"
    @clock.advance(EC::GRACE_PERIOD_SECONDS)
    login("dona@gama.test")
    [["/financeiro/provedor", { "provedor" => "simulator", "nome" => "Simulador" }],
     ["/financeiro/reservas/#{reservation.id}/sincronizar", {}],
     ["/usuarios/convites", { "email" => "novo@gama.test", "papel" => "attendant" }],
     ["/integracoes", { "url" => "http://127.0.0.1:9/hook", "eventos" => ["*"] }]].each do |path, params|
      post_form path, params

      assert_equal 403, last_response.status, path
      assert_includes last_response.body, "#{REFUSED}: o prazo de confirmação terminou.", path
    end
  end

  def test_read_only_account_can_still_switch_organization_resend_and_log_out
    @clock.advance(EC::GRACE_PERIOD_SECONDS)
    login("dona@gama.test")
    get "/organizacoes"

    assert_equal 200, last_response.status
    post_form "/organizacoes/ativar", { "organizacao_id" => @gamma[:organization_id], "tipo" => "staff" }

    assert_equal 303, last_response.status
    follow_redirect!
    resend

    assert_equal 303, last_response.status
    post_form "/sair", {}

    assert_equal "/entrar", last_response.location
  end

  def test_confirmation_link_removes_the_banner
    token = @system.transactor.call { |tx| @system.services[:tokens].issue(tx, @gamma[:user_id], "email_confirmation", 3600) }
    get "/confirmar-email", { "token" => token }
    follow_redirect!

    assert_includes last_response.body, "E-mail confirmado."
    assert_nil banner
  end

  def test_session_api_answers_forbidden_with_its_own_code
    session_api("/quotes/#{@gamma_quote.id}/send")

    assert_equal 403, last_response.status
    assert_error "email_unconfirmed"
    assert_includes error_message, "Confirme seu e-mail para enviar orçamentos aos clientes"
    @clock.advance(EC::GRACE_PERIOD_SECONDS)
    login("dona@gama.test")
    session_api("/customers", { "kind" => "individual", "name" => "Pela API", "document" => "39053344705" })

    assert_equal 403, last_response.status
    assert_error "email_unconfirmed"
    assert_equal REFUSED, error_message[0, REFUSED.length]
    get "/api/v1/customers"

    assert_equal 200, last_response.status, "consulta liberada na conta somente leitura"
  end

  # Credencial criada por conta ainda não confirmada (implantação gradual com a 1.3.0) herda a situação do criador.
  def test_credential_of_an_unconfirmed_creator_answers_forbidden_with_the_same_code
    confirm_email(@gamma[:user_id])
    bearer = token(%w[quotes.write quotes.read customers.read], actor: @gamma_actor)
    owner_query("UPDATE users SET email_confirmed_at = NULL WHERE id = $1", [@gamma[:user_id]], tenant: "")
    post!(403, "/quotes/#{@gamma_quote.id}/send", {}, token: bearer)

    assert_error "email_unconfirmed"
    get!(200, "/customers", {}, token: bearer)
  end

  def correction(params, token: csrf, env: {})
    post "/confirmar-email/corrigir", { "_csrf" => token }.merge(params), env
  end

  def test_banner_shows_the_address_and_links_to_the_correction
    get "/clientes"

    assert_includes banner, "Enviamos a confirmação para <strong>dona@gama.test</strong>."
    assert_includes banner, %(<a href="/confirmar-email/corrigir">Corrigir e-mail</a>)
    get "/confirmar-email/corrigir"

    assert_equal 200, last_response.status
    assert_includes last_response.body, %(action="/confirmar-email/corrigir")
    assert_includes last_response.body, %(name="senha" type="password" autocomplete="current-password")
    assert_includes last_response.body, "dona@gama.test"
  end

  def test_read_only_account_corrects_the_email_with_the_current_password
    @clock.advance(EC::GRACE_PERIOD_SECONDS)
    login("dona@gama.test")
    get "/confirmar-email/corrigir"
    post "/confirmar-email/corrigir", { "email" => "gama@correta.test", "senha" => "senha-muito-segura-1" }

    assert_equal 403, last_response.status, "sem CSRF"
    get "/confirmar-email/corrigir"
    correction({ "email" => "gama@correta.test", "senha" => "senha-errada-1234" })

    assert_equal 422, last_response.status
    assert_includes last_response.body, "senha atual incorreta"
    correction({ "email" => "gama@correta.test", "senha" => "senha-muito-segura-1" })

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "E-mail corrigido. Enviamos o link de confirmação para gama@correta.test."
    assert_includes banner, "Enviamos a confirmação para <strong>gama@correta.test</strong>."
    assert_includes banner, LOCKED, "a conta continua somente leitura até a confirmação"
  end

  def test_correction_is_limited_per_ip_and_unavailable_for_confirmed_accounts
    get "/confirmar-email/corrigir"
    token = csrf
    20.times { @system.services[:rate_limiter].hit("email_confirmation:ip:127.0.0.1", limit: 20, window_seconds: 3600) }
    correction({ "email" => "gama@correta.test", "senha" => "senha-muito-segura-1" }, token: token)

    assert_equal 429, last_response.status
    confirm_email(@gamma[:user_id])
    get "/confirmar-email/corrigir"

    assert_equal "/", last_response.location
    follow_redirect!

    assert_includes last_response.body, "Seu e-mail já está confirmado."
  end

  def test_openapi_documents_the_code
    get "/api/v1/openapi.yaml"

    assert_includes last_response.body, "email_unconfirmed"
  end
end
