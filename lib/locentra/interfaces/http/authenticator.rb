# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      # Resolve a identidade da requisição. O tenant vem sempre da sessão ou da credencial
      # verificada; parâmetros e cabeçalhos não definem organização.
      class Authenticator
        def initialize(system)
          @system = system
          @sessions = system.services[:sessions]
        end

        def self.cookie_name(config) = config.secure_cookies? ? "__Host-locentra" : "locentra_session"

        # Modos: :public (sessão opcional), :login (sessão sem organização), :session (equipe),
        # :portal (cliente), :api (credencial Bearer ou sessão de equipe).
        def authenticate!(ctx, mode)
          case mode
          when :public then load_session(ctx)
          when :login then require_login!(ctx)
          when :session then staff!(ctx)
          when :portal then portal!(ctx)
          when :api then api!(ctx)
          when :staff_or_portal then staff_or_portal!(ctx)
          else raise ArgumentError, "modo de autenticação desconhecido: #{mode}"
          end
        end

        private

        def load_session(ctx)
          token = ctx.cookie(self.class.cookie_name(@system.config))
          ctx.session = token && @sessions.resolve(token)
        end

        def require_login!(ctx)
          load_session(ctx)
          raise Unauthenticated unless ctx.session
        end

        def staff!(ctx)
          require_login!(ctx)
          session = ctx.session
          raise Unauthenticated, "selecione uma organização" unless session["kind"] == "staff" && session["organization_id"]

          membership = @system.uow.anonymous(tenant_id: session["organization_id"], user_id: session["user_id"]) do |tx|
            [@system.repos[:access].active_membership(tx, session["organization_id"], session["user_id"]),
             @system.repos[:organizations].find(tx, session["organization_id"])]
          end
          raise Domain::AccessDenied, "acesso à organização revogado" unless membership.first

          ctx.organization = membership.last
          ctx.actor = Application::Actor.user(user_id: session["user_id"], organization_id: session["organization_id"],
                                              role: membership.first["role"], membership_id: membership.first["id"],
                                              request_id: ctx.request_id, ip: ctx.ip)
        end

        def portal!(ctx)
          require_login!(ctx)
          session = ctx.session
          raise Unauthenticated unless session["kind"] == "portal" && session["organization_id"]

          access, org = @system.uow.anonymous(tenant_id: session["organization_id"], user_id: session["user_id"]) do |tx|
            [@system.repos[:access].active_portal_access(tx, session["organization_id"], session["user_id"]),
             @system.repos[:organizations].find(tx, session["organization_id"])]
          end
          raise Domain::AccessDenied, "acesso ao portal revogado" unless access

          ctx.organization = org
          ctx.actor = Application::Actor.customer(user_id: session["user_id"], organization_id: session["organization_id"],
                                                  customer_id: access["customer_id"], request_id: ctx.request_id, ip: ctx.ip)
        end

        def staff_or_portal!(ctx)
          require_login!(ctx)
          ctx.session["kind"] == "portal" ? portal!(ctx) : staff!(ctx)
        end

        def api!(ctx)
          header = ctx.env["HTTP_AUTHORIZATION"].to_s
          return staff!(ctx) if header.empty?

          token = header[/\ABearer\s+(\S+)\z/, 1]
          raise Unauthenticated, "credencial ausente ou malformada" unless token

          actor = @system.use_cases[:authenticate_credential].call(token, request_id: ctx.request_id, ip: ctx.ip)
          raise Unauthenticated, "credencial inválida" unless actor

          ctx.env["locentra.auth_method"] = "bearer"
          ctx.actor = actor
          ctx.organization = @system.uow.run(actor) { |tx, _| @system.repos[:organizations].find(tx, actor.organization_id) }
        end
      end
    end
  end
end
