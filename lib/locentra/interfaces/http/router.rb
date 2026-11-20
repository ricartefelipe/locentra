# frozen_string_literal: true

module Locentra
  module Interfaces
    module HTTP
      # Tabela de rotas explícita. Cada rota declara verbo, padrão, controlador, ação e modo de
      # autenticação (:public, :session, :api, :portal). Padrões aceitam segmentos `:nome`, que
      # casam apenas com caracteres seguros (sem barra, sem ponto-ponto).
      class Router
        Route = Data.define(:verb, :pattern, :controller, :action, :auth, :regex, :names, :options) do
          def match(verb, path)
            return nil unless verb == self.verb || (self.verb == "GET" && verb == "HEAD")

            data = regex.match(path)
            data && names.zip(data.captures).to_h
          end
        end

        SEGMENT = "([A-Za-z0-9_-]{1,64})"

        def initialize
          @routes = []
        end

        def add(verb, pattern, controller, action, auth: :session, **options)
          names = pattern.scan(/:([a-z_]+)/).flatten
          regex = Regexp.new("\\A#{pattern.gsub(/:[a-z_]+/, SEGMENT)}\\z")
          @routes << Route.new(verb: verb, pattern: pattern, controller: controller, action: action, auth: auth, regex: regex,
                               names: names, options: options)
        end

        def get(pattern, controller, action, **) = add("GET", pattern, controller, action, **)
        def post(pattern, controller, action, **) = add("POST", pattern, controller, action, **)

        # Retorna [rota, parâmetros] ou [nil, métodos permitidos] para 404/405.
        def recognize(verb, path)
          allowed = []
          @routes.each do |route|
            data = route.regex.match(path)
            next unless data

            params = route.match(verb, path)
            return [route, params] if params

            allowed << route.verb
          end
          [nil, allowed.uniq]
        end

        def routes = @routes.dup
      end
    end
  end
end
