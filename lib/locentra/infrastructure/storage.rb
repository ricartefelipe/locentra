# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module Locentra
  module Infrastructure
    module Storage
      class InvalidKey < StandardError; end

      # Armazenamento local fora do diretório público. Chaves são geradas pelo servidor no formato
      # "<organização>/<anexo>" (UUIDs); qualquer outra forma é rejeitada e o caminho resolvido
      # precisa permanecer sob a raiz configurada.
      class Local
        KEY = %r{\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z}

        def initialize(root:)
          @root = File.expand_path(root)
        end

        def put(key, bytes)
          path = path_for(key)
          FileUtils.mkdir_p(File.dirname(path), mode: 0o750)
          temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o640) { |file| file.write(bytes) }
          File.rename(temporary, path)
          { byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes) }
        ensure
          FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
        end

        def get(key)
          File.binread(path_for(key))
        end

        def delete(key)
          FileUtils.rm_f(path_for(key))
        end

        def exist?(key) = File.file?(path_for(key))

        def path_for(key)
          raise InvalidKey, "chave de armazenamento inválida" unless key.to_s.match?(KEY)

          path = File.expand_path(key, @root)
          raise InvalidKey, "caminho fora da raiz de armazenamento" unless path.start_with?("#{@root}/")

          path
        end
      end
    end
  end
end
