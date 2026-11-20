# frozen_string_literal: true

require "erb"

module Locentra
  module Infrastructure
    # Templates de e-mail em texto puro. A primeira linha define o assunto ("Assunto: ...").
    class MailTemplates
      NAME = /\A[a-z_]+\z/

      def initialize(root:)
        @root = root
      end

      def render(name, vars)
        raise ArgumentError, "template inválido" unless name.to_s.match?(NAME)

        source = File.read(File.join(@root, "#{name}.text.erb"))
        text = ERB.new(source, trim_mode: "-").result_with_hash(v: vars.transform_keys(&:to_s))
        first, body = text.split("\n", 2)
        raise ArgumentError, "template sem assunto" unless first.start_with?("Assunto: ")

        [first.delete_prefix("Assunto: ").gsub(/[\r\n]/, " ").strip, body.to_s.lstrip]
      end
    end
  end
end
