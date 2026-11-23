# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        class DashboardController < Controller
          def show(ctx)
            data = uc(:dashboard).call(ctx.actor)
            render(ctx, "dashboard/show", title: "Painel", data: data)
          end
        end

        class CustomersController < Controller
          # Condições negociadas exibidas na página do cliente e produtos oferecidos no seletor.
          AGREEMENTS_LIMIT = 100

          def index(ctx)
            page = uc(:list_customers).call(ctx.actor, search: ctx.query("busca"), status: blank(ctx.query("situacao")),
                                                       limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "customers/index", title: "Clientes", page: page, search: ctx.query("busca").to_s, filter_status: ctx.query("situacao").to_s)
          end

          def new(ctx)
            render(ctx, "customers/new", title: "Novo cliente", values: { "tipo" => "individual" }, errors: {})
          end

          def create(ctx)
            f = ctx.form
            customer = uc(:create_customer).call(ctx.actor, { kind: f["tipo"], name: f["nome"], document: f["documento"], trade_name: f["nome_fantasia"],
                                                              email: f["email"], phone: f["telefone"], notes: f["observacoes"] })
            redirect(ctx, "/clientes/#{customer.id}", notice: "Cliente cadastrado.")
          rescue Domain::ValidationError, Domain::Conflict => e
            render(ctx, "customers/new", title: "Novo cliente", status: 422, values: f, errors: errors_of(e))
          end

          def show(ctx, errors: {}, status: 200)
            data = uc(:get_customer).call(ctx.actor, ctx.param(:id))
            reservations = uc(:list_reservations).call(ctx.actor, customer_id: data[:customer].id, limit: 10)
            attachments = @system.uow.run(ctx.actor, "customers.read") do |tx, _|
              @system.repos[:attachments].for_owner(tx, "customer", data[:customer].id)
            end
            portal = uc(:list_portal_accesses).call(ctx.actor, data[:customer].id)
            render(ctx, "customers/show", title: data[:customer].name, status: status, data: data, reservations: reservations, errors: errors,
                                          attachments: attachments, portal: portal, now: @system.clock.now, **agreements_for(ctx, data[:customer]))
          end

          def update(ctx)
            f = ctx.form
            uc(:update_customer).call(ctx.actor, ctx.param(:id), { name: f["nome"], email: f["email"], phone: f["telefone"], notes: f["observacoes"],
                                                                   status: f["situacao"], trade_name: f["nome_fantasia"] })
            redirect(ctx, "/clientes/#{ctx.param(:id)}", notice: "Cliente atualizado.")
          rescue Domain::ValidationError => e
            show(ctx, errors: e.errors, status: 422)
          end

          def add_contact(ctx)
            f = ctx.form
            uc(:add_contact).call(ctx.actor, ctx.param(:id), { name: f["nome"], email: f["email"], phone: f["telefone"], role: f["funcao"],
                                                               document: f["documento"], authorized_pickup: f["autorizado"] == "1" })
            redirect(ctx, "/clientes/#{ctx.param(:id)}", notice: "Contato adicionado.")
          rescue Domain::ValidationError => e
            show(ctx, errors: e.errors, status: 422)
          end

          def add_address(ctx)
            f = ctx.form
            uc(:add_address).call(ctx.actor, ctx.param(:id), { label: f["rotulo"], street: f["logradouro"], number: f["numero"],
                                                               complement: f["complemento"], district: f["bairro"], city: f["cidade"],
                                                               state: f["uf"], postal_code: f["cep"] })
            redirect(ctx, "/clientes/#{ctx.param(:id)}", notice: "Endereço adicionado.")
          rescue Domain::ValidationError => e
            show(ctx, errors: e.errors, status: 422)
          end

          # Condição negociada do cliente: produto pelo SKU (vazio = condição geral), desconto percentual e
          # vigência no fuso da organização. Sobreposição com outra condição do mesmo escopo aparece no
          # campo do início da vigência.
          def create_agreement(ctx)
            uc(:create_price_agreement).call(ctx.actor, ctx.param(:id), agreement_attrs(ctx))
            redirect(ctx, agreements_path(ctx), notice: "Condição negociada cadastrada. Reservas e orçamentos já registrados não mudam.")
          rescue Domain::ValidationError => e
            show(ctx, errors: e.errors, status: 422)
          rescue Domain::Conflict => e
            show(ctx, errors: { (e.code == "price_agreement_overlap" ? "valido_de" : "base") => [e.message] }, status: 409)
          rescue Domain::NotFound => e
            raise unless e.message.start_with?("produto")

            show(ctx, errors: { "produto" => [e.message] }, status: 422)
          end

          # Encerramento único, imediato (campo vazio) ou agendado, com motivo obrigatório.
          def end_agreement(ctx)
            at = optional_local_time(ctx, ctx.form["encerrar_em"], "encerrar_em")
            ended = uc(:end_price_agreement).call(ctx.actor, ctx.param(:condicao_id), reason: ctx.form["motivo"], at: at, customer_id: ctx.param(:id))
            notice = if ended.end_scheduled?(@system.clock.now)
                       "Encerramento agendado para #{ctx.time_zone.format_local(ended.ended_at)}."
                     else
                       "Condição negociada encerrada. Reservas e orçamentos já registrados não mudam."
                     end
            redirect(ctx, agreements_path(ctx), notice: notice)
          rescue Domain::ValidationError, Domain::InvalidTransition => e
            show(ctx, errors: errors_of(e), status: 422)
          end

          private

          def blank(value) = value.to_s.empty? ? nil : value

          def errors_of(error) = error.is_a?(Domain::ValidationError) ? error.errors : { "base" => [error.message] }

          # Seção de condições negociadas: somente com a permissão de leitura; os produtos ativos do
          # seletor, somente para quem pode cadastrar.
          def agreements_for(ctx, customer)
            return { agreements: nil, agreement_products: [] } unless ctx.can?("price_agreements.read")

            products = if ctx.can?("price_agreements.write") && ctx.can?("catalog.read")
                         uc(:list_products).call(ctx.actor, limit: AGREEMENTS_LIMIT).items.select(&:active)
                       else
                         []
                       end
            { agreements: uc(:list_price_agreements).call(ctx.actor, customer.id, limit: AGREEMENTS_LIMIT), agreement_products: products }
          end

          def agreement_attrs(ctx)
            f = ctx.form
            Domain::Pricing::Input.collect do |check|
              { product: f["produto"], notes: f["observacoes"],
                discount_bps: check.call("desconto") { Domain::Percent.parse(f["desconto"], "desconto") },
                valid_from: check.call("valido_de") { optional_local_time(ctx, f["valido_de"], "valido_de") },
                valid_until: check.call("valido_ate") { optional_local_time(ctx, f["valido_ate"], "valido_ate") } }
            end
          end

          # Sem âncora: o aviso fica no topo da página e precisa estar visível depois do redirecionamento.
          def agreements_path(ctx) = "/clientes/#{Domain::Identifier.parse(ctx.param(:id), "cliente")}"
        end

        class AuditController < Controller
          def index(ctx)
            filters = { "action" => ctx.query("acao"), "resource_type" => ctx.query("recurso") }
            page = uc(:list_audit).call(ctx.actor, filters: filters, limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "audit/index", title: "Auditoria", page: page, filters: filters)
          end
        end

        class MembersController < Controller
          def index(ctx, errors: {}, status: 200, token: nil)
            data = uc(:list_members).call(ctx.actor)
            credentials = ctx.can?("integrations.manage") ? uc(:list_credentials).call(ctx.actor) : []
            render(ctx, "members/index", title: "Usuários e permissões", status: status, data: data, credentials: credentials,
                                         errors: errors, token: token, roles: Domain::Identity.assignable_roles(ctx.actor.role))
          end

          def invite(ctx)
            uc(:invite_member).call(ctx.actor, email: ctx.form["email"], role: ctx.form["papel"].to_s)
            redirect(ctx, "/usuarios", notice: "Convite enviado para #{ctx.form["email"]}.")
          rescue Domain::ValidationError, Domain::Conflict, Domain::PlanLimitExceeded, OutboundRefusal => e
            index(ctx, errors: e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }, status: 422)
          end

          def change_role(ctx)
            uc(:change_member_role).call(ctx.actor, membership_id: ctx.param(:id), role: ctx.form["papel"].to_s)
            redirect(ctx, "/usuarios", notice: "Papel alterado.")
          end

          def revoke(ctx)
            uc(:revoke_membership).call(ctx.actor, membership_id: ctx.param(:id))
            redirect(ctx, "/usuarios", notice: "Acesso revogado.")
          end

          def create_credential(ctx)
            row = uc(:create_credential).call(ctx.actor, name: ctx.form["nome"], scopes: Array(ctx.form["escopos"]), kind: ctx.form["tipo"].to_s,
                                                         expires_in_days: ctx.form["validade"].to_s)
            index(ctx, token: row["token"])
          rescue Domain::ValidationError, Domain::PlanLimitExceeded, FormDenial => e
            index(ctx, errors: e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }, status: 422)
          end

          def revoke_credential(ctx)
            uc(:revoke_credential).call(ctx.actor, ctx.param(:id))
            redirect(ctx, "/usuarios", notice: "Credencial revogada.")
          end
        end

        class HealthController < Controller
          def live(_ctx) = json(200, { "status" => "ok" })

          def ready(_ctx)
            checks = { "database" => database_ok?, "migrations" => migrations_ok? }
            json(checks.values.all? ? 200 : 503, { "status" => checks.values.all? ? "ok" : "degraded", "checks" => checks })
          end

          # Em produção as métricas exigem METRICS_TOKEN: sem ele, o endpoint fica desativado (404) em vez
          # de expor volume por rota, fila e falhas a qualquer pessoa.
          def metrics(ctx)
            expected = @system.config.metrics_token
            if expected.nil? && @system.config.production?
              return [404, { "content-type" => "text/plain; charset=utf-8" }, ["métricas desativadas: defina METRICS_TOKEN"]]
            end
            if expected && !Rack::Utils.secure_compare(ctx.env["HTTP_AUTHORIZATION"].to_s, "Bearer #{expected}")
              return [401, { "content-type" => "text/plain" }, ["não autorizado"]]
            end

            uc(:collect_metrics).call
            [200, { "content-type" => "text/plain; version=0.0.4" }, [@system.metrics.render]]
          end

          private

          def database_ok?
            @system.transactor.call { |tx| tx.query_value("SELECT 1") == 1 }
          rescue StandardError => e
            check_failed("database", e)
          end

          def migrations_ok?
            @system.transactor.call do |tx|
              applied = tx.query("SELECT version FROM schema_migrations").map { |r| r["version"] }
              files = Dir.children(File.join(App::ROOT, "db/migrations")).filter_map { |f| f[/\A(\d{4})_/, 1] }
              (files - applied).empty?
            end
          rescue StandardError => e
            check_failed("migrations", e)
          end

          def check_failed(check, error)
            @system.logger.warn(event: "health.check_failed", check: check, error: error.class.name, message: error.message)
            false
          end
        end
      end
    end
  end
end
