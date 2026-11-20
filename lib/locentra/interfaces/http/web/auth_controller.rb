# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        # Entrada, cadastro, seleção de organização, saída, confirmação de e-mail, recuperação de
        # senha e aceite de convite.
        class AuthController < Controller
          # Página de aceite do convite do portal: pública, preservada após a entrada para vincular a conta.
          PORTAL_INVITATION = "/portal/convite"

          def login_form(ctx)
            return redirect(ctx, home_of(ctx.session["kind"])) if ctx.session && ctx.session["organization_id"]

            render(ctx, "auth/login", title: "Entrar", layout: "layouts/public", values: {}, error: nil, back: safe_back(ctx.query("voltar")))
          end

          def login(ctx)
            user = uc(:authenticate).call(email: ctx.form["email"], password: ctx.form["senha"], ip: ctx.ip)
            memberships = uc(:list_memberships).call(user["id"])
            token, = @system.services[:sessions].create(user_id: user["id"], organization_id: single_org(memberships), kind: kind_for(memberships),
                                                        ip: ctx.ip, user_agent: ctx.user_agent, rotate_from: ctx.session&.fetch("id"))
            target = login_target(memberships, safe_back(ctx.form["voltar"]))
            redirect(ctx, target) { |response| session_cookie(response, token) }
          rescue Application::Identity::AuthenticationFailed, Application::Identity::TooManyRequests => e
            render(ctx, "auth/login", title: "Entrar", layout: "layouts/public", status: e.is_a?(Application::Identity::TooManyRequests) ? 429 : 401,
                                      values: { "email" => ctx.form["email"] }, error: e.message, back: safe_back(ctx.form["voltar"]))
          end

          def logout(ctx)
            @system.services[:sessions].revoke(ctx.session["id"]) if ctx.session
            redirect(ctx, "/entrar", notice: "Sessão encerrada.") { |response| clear_session_cookie(response) }
          end

          def organizations(ctx)
            memberships = uc(:list_memberships).call(ctx.session["user_id"])
            render(ctx, "auth/organizations", title: "Organizações", layout: "layouts/public", memberships: memberships)
          end

          def switch(ctx)
            org_id = ctx.form["organizacao_id"].to_s
            kind = ctx.form["tipo"].to_s
            memberships = uc(:list_memberships).call(ctx.session["user_id"])
            # O mesmo usuário pode ter vínculo de equipe e acesso ao portal na mesma organização.
            membership = memberships.find { |m| m["organization_id"] == org_id && (kind.empty? || m["kind"] == kind) }
            raise Domain::AccessDenied, "sem acesso à organização" unless membership

            token, = @system.services[:sessions].create(user_id: ctx.session["user_id"], organization_id: membership["organization_id"],
                                                        kind: membership["kind"], ip: ctx.ip, user_agent: ctx.user_agent,
                                                        rotate_from: ctx.session["id"])
            redirect(ctx, landing(membership, nil), notice: "Organização ativa: #{membership["name"]}") { |response| session_cookie(response, token) }
          end

          def signup_form(ctx)
            plans = @system.uow.anonymous { |tx| @system.repos[:organizations].plans(tx) }
            render(ctx, "auth/signup", title: "Criar conta", layout: "layouts/public", plans: plans, values: { "plano" => "profissional" }, errors: {})
          end

          def signup(ctx)
            f = ctx.form
            result = uc(:sign_up).call(name: f["nome"], email: f["email"], password: f["senha"], organization_name: f["organizacao"],
                                       plan_id: f["plano"].to_s, timezone: "America/Sao_Paulo", request_id: ctx.request_id)
            token, = @system.services[:sessions].create(user_id: result[:user_id], organization_id: result[:organization_id], ip: ctx.ip,
                                                        user_agent: ctx.user_agent)
            redirect(ctx, "/", notice: "Organização criada. Enviamos um e-mail para confirmar seu endereço.") { |r| session_cookie(r, token) }
          rescue Domain::ValidationError, Domain::Conflict => e
            plans = @system.uow.anonymous { |tx| @system.repos[:organizations].plans(tx) }
            errors = e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }
            render(ctx, "auth/signup", title: "Criar conta", layout: "layouts/public", status: 422, plans: plans,
                                       values: ctx.form.except("senha"), errors: errors)
          end

          def confirm_email(ctx)
            uc(:confirm_email).call(ctx.query("token"))
            redirect(ctx, ctx.session ? "/" : "/entrar", notice: "E-mail confirmado.")
          rescue Domain::ValidationError
            redirect(ctx, "/entrar", alert: "Link de confirmação inválido ou expirado.")
          end

          def forgot_form(ctx)
            render(ctx, "auth/forgot", title: "Recuperar senha", layout: "layouts/public", sent: false)
          end

          def forgot(ctx)
            uc(:request_password_reset).call(email: ctx.form["email"], ip: ctx.ip, request_id: ctx.request_id)
            render(ctx, "auth/forgot", title: "Recuperar senha", layout: "layouts/public", sent: true)
          end

          def reset_form(ctx)
            render(ctx, "auth/reset", title: "Nova senha", layout: "layouts/public", token: ctx.query("token").to_s, errors: {})
          end

          def reset(ctx)
            uc(:reset_password).call(token: ctx.form["token"], password: ctx.form["senha"])
            redirect(ctx, "/entrar", notice: "Senha alterada. Entre com a nova senha.")
          rescue Domain::ValidationError => e
            render(ctx, "auth/reset", title: "Nova senha", layout: "layouts/public", status: 422, token: ctx.form["token"].to_s, errors: e.errors)
          end

          def invitation_form(ctx)
            render(ctx, "auth/invitation", title: "Convite", layout: "layouts/public", token: ctx.query("token").to_s, errors: {})
          end

          # Com sessão, vincula a conta conectada: exige o token CSRF da sessão (como no portal).
          def accept_invitation(ctx)
            ctx.verify_csrf! if ctx.session
            result = uc(:accept_invitation).call(token: ctx.form["token"], user_id: ctx.session&.fetch("user_id"),
                                                 name: ctx.form["nome"], password: ctx.form["senha"])
            token, = @system.services[:sessions].create(user_id: result[:user_id], organization_id: result[:organization_id], ip: ctx.ip,
                                                        user_agent: ctx.user_agent, rotate_from: ctx.session&.fetch("id"))
            redirect(ctx, "/", notice: "Convite aceito.") { |response| session_cookie(response, token) }
          rescue Domain::ValidationError, Domain::Conflict, Domain::AccessDenied => e
            errors = e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }
            render(ctx, "auth/invitation", title: "Convite", layout: "layouts/public", status: 422, token: ctx.form["token"].to_s, errors: errors)
          end

          private

          def single_org(memberships) = memberships.size == 1 ? memberships.first["organization_id"] : nil
          def kind_for(memberships) = memberships.size == 1 ? memberships.first["kind"] : "staff"

          def login_target(memberships, back)
            return back if back&.start_with?(PORTAL_INVITATION)
            return "/organizacoes" unless memberships.size == 1

            landing(memberships.first, back)
          end

          # Retorno solicitado somente quando pertence à área da sessão criada (portal ou equipe).
          def landing(membership, back)
            portal = membership["kind"] == "portal"
            return back if back && portal_path?(back) == portal

            home_of(membership["kind"])
          end

          def home_of(kind) = kind == "portal" ? "/portal" : "/"
          def portal_path?(path) = path == "/portal" || path.start_with?("/portal/", "/portal?")

          def safe_back(value)
            Controller.local_path?(value) ? value.to_s : nil
          end
        end
      end
    end
  end
end
