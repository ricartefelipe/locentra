# frozen_string_literal: true

require "optparse"

module Locentra
  module Interfaces
    module CLI
      class UsageError < StandardError; end

      # Códigos de saída documentados (baseados em sysexits.h).
      module ExitCodes
        OK = 0
        BUSINESS = 1
        CONFIG = 2
        USAGE = 64
        UNAVAILABLE = 69
        INTERNAL = 70
        DENIED = 77
        INTERRUPTED = 130

        DESCRIPTIONS = {
          OK => "sucesso",
          BUSINESS => "erro de negócio ou validação (dados inválidos, recurso inexistente ou de outra organização)",
          CONFIG => "configuração ou conexão (credencial ausente, arquivo de credencial inseguro, variáveis ou banco indisponível)",
          USAGE => "uso incorreto (comando, opção ou argumento inválido)",
          UNAVAILABLE => "indisponível ou conflito (estado incompatível, disponibilidade insuficiente, provedor fora do ar)",
          INTERNAL => "erro interno inesperado (detalhes no log em stderr)",
          DENIED => "permissão negada (credencial inválida, revogada, expirada, de outro tipo ou sem o escopo)",
          INTERRUPTED => "interrompido pelo usuário"
        }.freeze
      end

      # Comando: palavras que o identificam, método em Commands, argumento posicional opcional
      # (no máximo um), opções aceitas e opções obrigatórias.
      Command = Data.define(:words, :handler, :argument, :options, :summary, :required) do
        def initialize(required: [], **)
          super
        end

        def name = words.join(" ")
        def usage = [name, argument].compact.join(" ")
      end

      COMMANDS = [
        Command.new(words: %w[whoami], handler: :whoami, argument: nil, options: [], summary: "Credencial, organização e escopos em uso"),
        Command.new(words: %w[availability], handler: :availability, argument: nil, options: %i[branch starts ends products],
                    required: %i[starts ends], summary: "Disponibilidade por filial e período"),
        Command.new(words: %w[reservations list], handler: :reservations_list, argument: nil,
                    options: %i[status customer search from to sort limit offset], summary: "Reservas com filtros e paginação"),
        Command.new(words: %w[reservations show], handler: :reservations_show, argument: "CÓDIGO|ID", options: [],
                    summary: "Detalhes de uma reserva"),
        Command.new(words: %w[asset show], handler: :asset_show, argument: "PATRIMÔNIO|ID", options: [],
                    summary: "Situação física, alocações e histórico de um ativo"),
        Command.new(words: %w[finance reconcile], handler: :finance_reconcile, argument: nil, options: [],
                    summary: "Conciliação com o provedor de pagamentos e relatório"),
        Command.new(words: %w[jobs failures], handler: :jobs_failures, argument: nil, options: %i[limit],
                    summary: "Tarefas mortas (tentativas esgotadas) da organização"),
        Command.new(words: %w[jobs retry], handler: :jobs_retry, argument: "ID", options: [],
                    summary: "Reprocessa uma tarefa morta (exige jobs.manage; auditado)")
      ].freeze

      GROUPS = COMMANDS.select { |c| c.words.size == 2 }.map { |c| c.words.first }.uniq.freeze

      OPTIONS = {
        branch: ["--filial CÓDIGO|ID", "Filial (padrão: a única filial ativa da organização)"],
        starts: ["--inicio INSTANTE", "Início: ISO 8601 com fuso (2026-03-10T08:00:00-03:00) ou horário local (2026-03-10T08:00)"],
        ends: ["--fim INSTANTE", "Fim exclusivo, no mesmo formato de --inicio"],
        products: ["--produto SKU|ID", "Produto; repita a opção ou separe por vírgulas (padrão: todos os produtos ativos)"],
        status: ["--situacao SITUAÇÃO", "Situação da reserva: #{Domain::Reservations::STATUSES.keys.join(", ")}"],
        customer: ["--cliente ID", "Identificador do cliente"],
        search: ["--busca TEXTO", "Trecho do código da reserva ou do nome do cliente"],
        from: ["--de INSTANTE", "Reservas que terminam depois do instante (aceita data AAAA-MM-DD, início do dia local)"],
        to: ["--ate INSTANTE", "Reservas que começam antes do instante (aceita data AAAA-MM-DD, início do dia local)"],
        sort: ["--ordem=ORDEM", "Ordenação: #{Application::Reservations::ListReservations::SORTS.join(", ")} (padrão -starts_at)"],
        limit: ["--limite N", "Quantidade máxima de itens (1 a #{Application::MAX_PAGE_LIMIT})"],
        offset: ["--deslocamento N", "Quantidade de itens a pular (paginação)"]
      }.freeze

      Invocation = Data.define(:command, :options, :argument, :help, :json, :token_file)

      # Interpreta a linha de comando. Opções globais valem antes ou depois do comando; abreviações
      # de opções são recusadas (evita que `--token` seja lido como `--token-file`).
      class Parser
        TOKEN_ARGUMENT = "o token não é aceito como argumento (fica visível em ps e no histórico do shell); " \
                         "use a variável LOCENTRA_TOKEN ou --token-file CAMINHO"

        def parse(argv)
          args = argv.dup
          options = {}
          global_parser(options).order!(args)
          return finish(nil, options, nil) if options[:version]

          @command = resolve(args, options)
          return finish(nil, options, nil) unless @command

          command_parser(@command, options).parse!(args)
          finish(@command, options, positional(@command, args, options))
        end

        # Ajuda do comando interpretado, do grupo (ex.: `jobs --help`) ou geral.
        def help_text
          return command_parser(@command, {}).to_s if @command

          general_help(@group)
        end

        private

        def finish(command, options, argument)
          Invocation.new(command: command, options: options, argument: argument, help: options[:help] || options[:version] || false,
                         json: options[:json] || false, token_file: options[:token_file])
        end

        # Retorna o comando, ou nil quando a ajuda geral ou de um grupo foi pedida.
        def resolve(args, options)
          first = args.shift
          return requested_help(options) if first.nil?
          return COMMANDS.find { |c| c.words == [first] } || raise(UsageError, unknown(first)) unless GROUPS.include?(first)

          second = args.first
          return group_help(first, args, options) if second.nil? || second.start_with?("-")

          args.shift
          COMMANDS.find { |c| c.words == [first, second] } ||
            raise(UsageError, "subcomando desconhecido de #{first} (disponíveis: #{subcommands(first).join(", ")})")
        end

        def requested_help(options)
          raise UsageError, "informe um comando (use --help para ver a lista)" unless options[:help]

          nil
        end

        def group_help(group, args, options)
          raise UsageError, "informe o subcomando de #{group}: #{subcommands(group).join(", ")}" unless options[:help] || args.intersect?(%w[-h --help])

          options[:help] = true
          @group = group
          nil
        end

        def unknown(word)
          shown = word.match?(/\A[a-z][a-z-]{0,30}\z/) ? ": #{word}" : ""
          "comando desconhecido#{shown} (use --help para ver a lista)"
        end

        def subcommands(group) = COMMANDS.select { |c| c.words.first == group }.map { |c| c.words.last }

        def positional(command, args, options)
          return nil if options[:help]

          missing = command.required.reject { |key| options[key] }
          raise UsageError, "informe #{missing.map { |key| OPTIONS.fetch(key).first.split(/[ =]/).first }.join(" e ")}" unless missing.empty?
          raise UsageError, "argumentos inesperados para #{command.name}" if args.size > (command.argument ? 1 : 0)
          raise UsageError, "informe #{command.argument} (uso: bin/locentra #{command.usage})" if command.argument && args.empty?

          args.first
        end

        def global_parser(options)
          OptionParser.new do |opts|
            opts.require_exact = true
            global_options(opts, options)
          end
        end

        def global_options(opts, options)
          opts.on("--json", "Saída em JSON estável (erros em JSON no stderr)") { options[:json] = true }
          opts.on("--token-file CAMINHO", "Arquivo com a credencial (permissão 0600; tem precedência sobre LOCENTRA_TOKEN)") do |path|
            options[:token_file] = path
          end
          opts.on("--token [VALOR]", "Recusado: o token não é aceito por argumento") { raise UsageError, TOKEN_ARGUMENT }
          opts.on("-h", "--help", "Mostra esta ajuda") { options[:help] = true }
          opts.on("--version", "Mostra a versão") { options[:version] = true }
        end

        def command_parser(command, options)
          OptionParser.new do |opts|
            opts.require_exact = true
            opts.banner = "Uso: bin/locentra #{command.usage} [opções]\n\n#{command.summary}."
            opts.separator("")
            opts.separator("Opções:") unless command.options.empty?
            command.options.each { |key| define(opts, key, options) }
            opts.separator("")
            opts.separator("Opções globais:")
            global_options(opts, options)
          end
        end

        def define(opts, key, options)
          switch, description = OPTIONS.fetch(key)
          if key == :products
            opts.on(switch, Array, description) { |list| options[:products] = options.fetch(:products, []) + list }
          else
            opts.on(switch, description) { |value| options[key] = value }
          end
        end

        def general_help(group)
          listed = group ? COMMANDS.select { |c| c.words.first == group } : COMMANDS
          lines = ["Uso: bin/locentra [opções globais] COMANDO [opções] [argumento]", "",
                   "CLI operacional do Locentra: usa os mesmos casos de uso, permissões e auditoria da aplicação.",
                   "Comandos administrativos de banco ficam em bin/locentra-admin.", "", "Comandos:"]
          lines += listed.map { |c| format("  %<usage>-32s %<summary>s", usage: c.usage, summary: c.summary) }
          lines += ["", "Opções globais:", *global_parser({}).summarize.map(&:rstrip), "", *credential_help, "", "Códigos de saída:"]
          lines += ExitCodes::DESCRIPTIONS.map { |code, text| format("  %<code>3d  %<text>s", code: code, text: text) }
          lines.join("\n")
        end

        def credential_help
          ["Credencial:",
           "  Credencial de integração do tipo cli (Usuários e permissões > Credenciais de integração),",
           "  informada em LOCENTRA_TOKEN ou em --token-file. Banco: DATABASE_URL com o papel da aplicação.",
           "  Ajuda de um comando: bin/locentra COMANDO --help."]
        end
      end
    end
  end
end
