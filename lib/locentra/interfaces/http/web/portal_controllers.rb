# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      module Web
        # Telas do portal do cliente (modo de autenticação :portal). O ator é sempre o cliente do
        # acesso; os casos de uso filtram cada recurso pelo cliente e respondem "não encontrado" para
        # recursos de outros clientes ou organizações.
        class PortalController < Controller
          STATEMENT_PARAMS = %w[limite inicio caucoes_limite caucoes_inicio].freeze

          def home(ctx)
            render(ctx, "portal/home", title: "Início", data: uc(:portal_home).call(ctx.actor))
          end

          # Consulta por filial e período; o resultado traz o formulário de solicitação de reserva. A consulta
          # não grava nada e é sempre lida no fuso atual, inclusive ao reexibir uma solicitação recusada por
          # fuso divergente: a tabela, as quantidades e as observações voltam com o fuso atual no formulário.
          def availability(ctx, errors: {}, status: 200, values: nil)
            values ||= ctx.rack.GET
            branches = uc(:portal_availability).branches(ctx.actor)
            result = nil
            unless values["inicio"].to_s.empty?
              begin
                period = period_from(ctx, values["inicio"], values["fim"], check_zone: false)
                result = uc(:portal_availability).call(ctx.actor, branch_id: values["filial"], period: period,
                                                                  lines: lines_from(values["produto"], values["quantidade"]))
              rescue Domain::ValidationError, Domain::NotFound => e
                errors = errors.merge(errors_of(e))
              end
            end
            render(ctx, "portal/availability", title: "Disponibilidade e solicitação", status: status, branches: branches, result: result,
                                               values: values, errors: errors)
          end

          # Solicitação a partir da consulta de disponibilidade. Erros voltam à mesma tela, com os
          # dados informados.
          def request_reservation(ctx)
            f = ctx.form
            reservation = uc(:portal_request_reservation).call(ctx.actor, branch_id: f["filial"], period: period_from(ctx, f["inicio"], f["fim"]),
                                                                          lines: lines_from(f["produto"], f["quantidade"]), notes: f["observacoes"])
            redirect(ctx, "/portal/reservas/#{reservation.id}",
                     notice: "Solicitação #{reservation.code} registrada. A disponibilidade só é garantida após a confirmação da locadora.")
          rescue Domain::ValidationError, Domain::NotFound => e
            availability(ctx, errors: errors_of(e), status: 422, values: f)
          end

          # Extrato com paginação própria para cobranças (`inicio`/`limite`) e cauções
          # (`caucoes_inicio`/`caucoes_limite`).
          def finance(ctx)
            params = STATEMENT_PARAMS.to_h { |name| [name, ctx.query(name).to_s] }
            data = uc(:finance).customer_statement(ctx.actor, limit: params["limite"], offset: params["inicio"],
                                                              deposits_limit: params["caucoes_limite"], deposits_offset: params["caucoes_inicio"])
            render(ctx, "portal/finance", title: "Cobranças e saldos", data: data, paging: params)
          end

          private

          def errors_of(error) = error.is_a?(Domain::ValidationError) ? error.errors : { "base" => [error.message] }
        end

        class PortalReservationsController < Controller
          def index(ctx)
            page = uc(:list_reservations).call(ctx.actor, status: blank(ctx.query("situacao")), sort: "-starts_at", limit: ctx.query("limite"),
                                                          offset: ctx.query("inicio"))
            render(ctx, "portal/reservations", title: "Minhas reservas", page: page, filter_status: ctx.query("situacao").to_s)
          end

          def show(ctx)
            data = uc(:get_reservation).call(ctx.actor, ctx.param(:id))
            # Somente reserva, itens e resumo de valores chegam à tela: alocações de ativos e estoques são
            # dados internos, e a tela não mostra a origem das tarifas nem o valor padrão.
            render(ctx, "portal/reservation", title: "Reserva #{data[:reservation].code}", reservation: data[:reservation], items: data[:items],
                                              pricing: data[:pricing][:summary], cancellation_policy: data[:cancellation_policy])
          end

          private

          def blank(value) = value.to_s.empty? ? nil : value
        end

        class PortalQuotesController < Controller
          def index(ctx)
            page = uc(:list_quotes).call(ctx.actor, status: blank(ctx.query("situacao")), limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "portal/quotes", title: "Orçamentos", page: page, filter_status: ctx.query("situacao").to_s, now: @system.clock.now)
          end

          def show(ctx, errors: {}, status: 200)
            data = uc(:get_quote).call(ctx.actor, ctx.param(:id))
            render(ctx, "portal/quote", title: "Orçamento #{data[:quote].code}", status: status, data: data, errors: errors,
                                        version: data[:current] || data[:versions].max_by(&:number), now: @system.clock.now)
          end

          def approve(ctx)
            quote = uc(:approve_quote).call(ctx.actor, ctx.param(:id), version: ctx.form["versao"], approver_name: ctx.form["nome"])
            redirect(ctx, "/portal/orcamentos/#{quote.id}", notice: "Orçamento #{quote.code} aprovado (versão #{quote.approved_version}).")
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: errors_of(e), status: e.is_a?(Domain::Conflict) ? 409 : 422)
          end

          # A versão exibida acompanha a rejeição: se a locadora reenviou outra versão, a página volta
          # com a versão atual (409) e nada é gravado.
          def reject(ctx)
            quote = uc(:reject_quote).call(ctx.actor, ctx.param(:id), version: ctx.form["versao"], reason: ctx.form["motivo"])
            redirect(ctx, "/portal/orcamentos/#{quote.id}", notice: "Orçamento #{quote.code} rejeitado (versão #{quote.current_version}).")
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: errors_of(e), status: e.is_a?(Domain::Conflict) ? 409 : 422)
          end

          private

          def blank(value) = value.to_s.empty? ? nil : value

          def errors_of(error) = error.is_a?(Domain::ValidationError) ? error.errors : { "base" => [error.message] }
        end

        class PortalContractsController < Controller
          def index(ctx)
            page = uc(:list_contracts).call(ctx.actor, status: blank(ctx.query("situacao")), limit: ctx.query("limite"), offset: ctx.query("inicio"))
            render(ctx, "portal/contracts", title: "Contratos", page: page, filter_status: ctx.query("situacao").to_s)
          end

          def show(ctx, errors: {}, status: 200)
            data = uc(:get_contract).call(ctx.actor, ctx.param(:id))
            render(ctx, "portal/contract", title: "Contrato #{data[:contract].code}", status: status, data: data, errors: errors)
          end

          # Aceite eletrônico simples pelo próprio cliente (registrado com IP, navegador e instante) da
          # versão do documento exibida no formulário. Se um aditivo gerou versão nova nesse meio
          # tempo, a página volta com a versão vigente (409) e nenhum aceite é gravado.
          def accept(ctx)
            f = ctx.form
            contract = uc(:accept_contract).call(ctx.actor, ctx.param(:id), version: f["versao"], name: f["nome"], document: f["documento"],
                                                                            user_agent: ctx.user_agent, confirmed: f["declaracao"] == "1")
            redirect(ctx, "/portal/contratos/#{contract.id}",
                     notice: "Aceite eletrônico simples registrado (versão #{contract.current_document_version} do documento).")
          rescue Domain::ValidationError, Domain::InvalidTransition, Domain::Conflict => e
            show(ctx, errors: e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] },
                      status: e.is_a?(Domain::Conflict) ? 409 : 422)
          end

          private

          def blank(value) = value.to_s.empty? ? nil : value
        end

        # Aceite do convite do portal (rota pública). Sem sessão, cria a conta; com sessão, vincula a
        # conta conectada se o e-mail for o do convite, exigindo o token CSRF da sessão.
        class PortalInvitationsController < Controller
          def show(ctx)
            render(ctx, "portal/invitation", title: "Acesso ao portal do cliente", layout: "layouts/public", token: ctx.query("token").to_s,
                                             errors: {})
          end

          def accept(ctx)
            ctx.verify_csrf! if ctx.session
            result = uc(:accept_portal_invitation).call(token: ctx.form["token"], user_id: ctx.session&.fetch("user_id"), name: ctx.form["nome"],
                                                        password: ctx.form["senha"])
            token, = @system.services[:sessions].create(user_id: result[:user_id], organization_id: result[:organization_id], kind: "portal",
                                                        ip: ctx.ip, user_agent: ctx.user_agent, rotate_from: ctx.session&.fetch("id"))
            redirect(ctx, "/portal", notice: "Acesso ao portal ativado.") { |response| session_cookie(response, token) }
          rescue Domain::ValidationError, Domain::Conflict, Domain::AccessDenied, Domain::PlanLimitExceeded => e
            errors = e.is_a?(Domain::ValidationError) ? e.errors : { "base" => [e.message] }
            render(ctx, "portal/invitation", title: "Acesso ao portal do cliente", layout: "layouts/public", status: 422,
                                             token: ctx.form["token"].to_s, errors: errors)
          end
        end

        # Gestão de acessos ao portal na tela do cliente (equipe, permissão customers.write).
        class CustomerPortalController < Controller
          def invite(ctx)
            invitation = uc(:invite_portal_contact).call(ctx.actor, customer_id: ctx.param(:id), contact_id: ctx.form["contato_id"])
            back(ctx, notice: "Convite de acesso ao portal enviado para #{invitation.email}.")
          rescue Domain::ValidationError, Domain::Conflict, Domain::PlanLimitExceeded, Domain::AccessDenied => e
            back(ctx, alert: "Convite não enviado: #{e.message}")
          end

          def cancel_invitation(ctx)
            uc(:cancel_portal_invitation).call(ctx.actor, customer_id: ctx.param(:id), invitation_id: ctx.param(:convite_id))
            back(ctx, notice: "Convite cancelado.")
          rescue Domain::InvalidTransition => e
            back(ctx, alert: e.message)
          end

          def revoke(ctx)
            uc(:revoke_portal_access).call(ctx.actor, customer_id: ctx.param(:id), access_id: ctx.param(:acesso_id))
            back(ctx, notice: "Acesso ao portal revogado. As sessões do portal deste usuário foram encerradas.")
          rescue Domain::Conflict => e
            back(ctx, alert: e.message)
          end

          private

          def back(ctx, **message)
            redirect(ctx, "/clientes/#{Domain::Identifier.parse(ctx.param(:id), "cliente")}#portal", **message)
          end
        end
      end
    end
  end
end
