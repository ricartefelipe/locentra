# frozen_string_literal: true

# Relógio controlável para testes. Mutável por design, restrito à suíte.
class TestClock
  def initialize(now = Time.utc(2026, 3, 2, 12, 0, 0))
    @now = Time.at(now.to_i).utc
  end

  attr_reader :now

  def monotonic = @now.to_f

  def advance(seconds)
    @now += seconds
  end

  def travel_to(time)
    @now = Time.at(time.to_i).utc
  end
end

# Identificadores determinísticos em formato UUID.
class SequentialIds
  def initialize(prefix = 0)
    @prefix = prefix
    @counter = 0
    @mutex = Thread::Mutex.new
  end

  def uuid
    @mutex.synchronize do
      @counter += 1
      format("00000000-0000-7000-8%<prefix>03x-%<counter>012x", prefix: @prefix, counter: @counter)
    end
  end

  def token(_bytes = 32)
    "token-#{uuid}"
  end
end

module TimeHelpers
  def t(text)
    Time.iso8601(text)
  end

  def period(from, to)
    Locentra::Domain::Period.new(t(from), t(to))
  end

  def utc(*parts)
    Time.utc(*parts)
  end
end
