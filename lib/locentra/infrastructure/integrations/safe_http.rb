# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "resolv"
require "timeout"
require "uri"

module Locentra
  module Infrastructure
    module Integrations
      # Erro declarado pela aplicação (porta HTTP de destinos configurados por usuários).
      UnsafeDestination = Application::Integrations::UnsafeDestination

      # Resposta que não terminou dentro do prazo total da entrega.
      class DeadlineExceeded < StandardError; end

      # Cliente HTTP para destinos configurados por usuários (webhooks), com proteção contra SSRF:
      #
      # - somente https (http apenas com permissão explícita, para testes locais);
      # - sem credenciais na URL e sem portas administrativas;
      # - todos os endereços resolvidos precisam ser públicos (bloqueia privados, loopback, link-local,
      #   metadados de nuvem, multicast, reservados e IPv4 mapeado em IPv6);
      # - a conexão usa o IP validado (evita DNS rebinding entre validação e conexão);
      # - redirecionamentos não são seguidos;
      # - tempos limite por operação de rede e prazo total da requisição (conexão, envio, cabeçalhos e
      #   corpo): um destino que responde gotejando não prende a thread do worker além do prazo;
      # - o corpo da resposta é lido em partes e a leitura é interrompida ao atingir
      #   MAX_RESPONSE_BYTES (o restante nunca é carregado em memória);
      # - sem nova tentativa automática do Net::HTTP (a fila decide as novas tentativas).
      class SafeHttp
        Response = Data.define(:status, :body)

        BLOCKED_RANGES = %w[
          0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
          192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
          ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8
        ].map { |cidr| IPAddr.new(cidr) }.freeze
        BLOCKED_PORTS = [22, 23, 25, 110, 143, 3306, 5432, 6379, 9200, 11_211, 27_017].freeze
        MAX_RESPONSE_BYTES = 4096
        TOTAL_TIMEOUT = 15

        def initialize(allow_http: false, allow_private: false, resolver: Resolv, open_timeout: 5, read_timeout: 10, total_timeout: TOTAL_TIMEOUT)
          @allow_http = allow_http
          @allow_private = allow_private
          @resolver = resolver
          @open_timeout = open_timeout
          @read_timeout = read_timeout
          @total_timeout = total_timeout
        end

        # Valida a URL e devolve [uri, ip] seguros; lança UnsafeDestination caso contrário.
        def resolve!(url)
          uri = URI.parse(url.to_s)
          raise UnsafeDestination, "use https" unless uri.is_a?(URI::HTTPS) || (@allow_http && uri.is_a?(URI::HTTP))
          raise UnsafeDestination, "URL sem host" if uri.host.to_s.empty?
          raise UnsafeDestination, "credenciais na URL não são permitidas" if uri.userinfo
          raise UnsafeDestination, "porta não permitida" if BLOCKED_PORTS.include?(uri.port)

          addresses = addresses_for(uri.host)
          raise UnsafeDestination, "host sem endereço" if addresses.empty?

          addresses.each { |ip| raise UnsafeDestination, "destino em rede interna ou reservada" if blocked?(ip) }
          [uri, addresses.first.to_s]
        rescue URI::InvalidURIError
          raise UnsafeDestination, "URL inválida"
        end

        def post(url, body, headers = {})
          uri, ip = resolve!(url)
          request = Net::HTTP::Post.new(uri.request_uri, headers.merge("content-type" => "application/json", "user-agent" => "Locentra-Webhooks/1"))
          request.body = body
          Timeout.timeout(@total_timeout, DeadlineExceeded, "resposta não concluída em #{@total_timeout}s") do
            connection(uri, ip).start { |http| perform(http, request) }
          end
        end

        def blocked?(ip)
          return false if @allow_private

          address = ip.is_a?(IPAddr) ? ip : IPAddr.new(ip.to_s)
          return true if address.ipv4_mapped? && blocked?(address.native)

          BLOCKED_RANGES.any? { |range| range.family == address.family && range.include?(address) }
        end

        private

        def connection(uri, ip)
          http = Net::HTTP.new(uri.host, uri.port)
          http.ipaddr = ip
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          http.write_timeout = @read_timeout
          http.max_retries = 0
          http
        end

        # Lê o corpo em partes e encerra a conexão ao atingir o limite, sem carregar o restante.
        def perform(http, request)
          status = nil
          buffer = +""
          catch(:limit) do
            http.request(request) do |response|
              status = response.code.to_i
              response.read_body do |chunk|
                buffer << chunk.byteslice(0, MAX_RESPONSE_BYTES - buffer.bytesize)
                throw :limit if buffer.bytesize >= MAX_RESPONSE_BYTES
              end
            end
          end
          Response.new(status: status, body: buffer)
        end

        def addresses_for(host)
          literal = host.delete_prefix("[").delete_suffix("]")
          return [IPAddr.new(literal)] if ip_literal?(literal)

          @resolver.getaddresses(host).map { |a| IPAddr.new(a.to_s) }.uniq
        rescue IPAddr::InvalidAddressError, Resolv::ResolvError
          []
        end

        def ip_literal?(text)
          IPAddr.new(text)
          true
        rescue IPAddr::InvalidAddressError
          false
        end
      end
    end
  end
end
