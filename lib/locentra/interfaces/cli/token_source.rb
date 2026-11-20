# frozen_string_literal: true

require_relative "../../config"

module Locentra
  module Interfaces
    module CLI
      # Origem da credencial da CLI operacional: variável LOCENTRA_TOKEN ou arquivo indicado em
      # `--token-file` (que tem precedência). O token nunca é aceito como argumento de linha de
      # comando, que fica visível em `ps` e no histórico do shell.
      #
      # O arquivo é aberto sem seguir links simbólicos e sem bloquear (FIFOs), e as verificações são
      # feitas no descritor já aberto, sem janela entre verificação e leitura: arquivo regular, do
      # usuário efetivo e sem nenhuma permissão para grupo e outros (0600 ou 0400). Mensagens de
      # erro não repetem o caminho nem o conteúdo.
      class TokenSource
        ENV_NAME = "LOCENTRA_TOKEN"
        MAX_BYTES = 512
        OPEN_FLAGS = File::RDONLY | File::NOFOLLOW | File::NONBLOCK

        # `uid`: usuário efetivo que deve ser o proprietário do arquivo (injetável em testes).
        def initialize(env:, file: nil, uid: Process.euid)
          @env = env
          @file = file
          @uid = uid
        end

        def read
          return from_file if @file

          token = @env[ENV_NAME].to_s.strip
          raise ConfigError, "credencial ausente: defina #{ENV_NAME} ou informe --token-file CAMINHO" if token.empty?

          token
        end

        private

        def from_file
          content = File.open(@file, OPEN_FLAGS) do |io|
            check!(io.stat)
            io.read(MAX_BYTES + 1).to_s
          end
          raise ConfigError, "arquivo de credencial acima de #{MAX_BYTES} bytes" if content.bytesize > MAX_BYTES

          token = content.strip
          raise ConfigError, "arquivo de credencial vazio" if token.empty?

          token
        rescue Errno::ENOENT, Errno::ENOTDIR
          raise ConfigError, "arquivo de credencial não encontrado"
        rescue Errno::ELOOP
          raise ConfigError, "o arquivo de credencial não pode ser um link simbólico"
        rescue Errno::EACCES
          raise ConfigError, "sem permissão de leitura no arquivo de credencial"
        rescue Errno::EISDIR
          raise ConfigError, "o arquivo de credencial deve ser um arquivo regular"
        end

        def check!(stat)
          raise ConfigError, "o arquivo de credencial deve ser um arquivo regular" unless stat.file?
          raise ConfigError, "o arquivo de credencial deve pertencer ao usuário que executa a CLI" unless stat.uid == @uid
          return if stat.mode.nobits?(0o077)

          raise ConfigError, format("o arquivo de credencial não pode ter permissão para grupo ou outros usuários (atual %<mode>04o; use chmod 600)",
                                    mode: stat.mode & 0o7777)
        end
      end
    end
  end
end
