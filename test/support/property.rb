# frozen_string_literal: true

# Testes baseados em propriedades com geração pseudoaleatória reproduzível.
#
# A semente deriva da semente do Minitest (--seed / SEED), de modo que uma falha pode ser
# reproduzida executando a suíte com a mesma semente. Cada caso gerado é reportado na
# mensagem de falha.
module PropertyTesting
  DEFAULT_RUNS = Integer(ENV.fetch("PROPERTY_RUNS", "200"))

  def property(name, runs: DEFAULT_RUNS)
    base_seed = Integer(ENV.fetch("SEED", Minitest.seed.to_s))
    runs.times do |iteration|
      seed = base_seed + iteration
      random = Random.new(seed)
      begin
        yield random
      rescue Minitest::Assertion => e
        raise Minitest::Assertion, "Propriedade '#{name}' falhou (semente #{seed}, iteração #{iteration}): #{e.message}"
      end
    end
  end
end
