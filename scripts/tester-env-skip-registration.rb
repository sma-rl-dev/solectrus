# frozen_string_literal: true

# Tester-environment adaptation: Solectrus' external registration/update check
# is not reachable or meaningful in the local training environment. The
# deployment opts in with TESTER_ENV_SKIP_REGISTRATION=true (the same switch the
# public launcher applies to UpdateCheck.skip_http?). This initializer supplies
# the switch to source baselines pinned before that line existed. It runs in
# to_prepare because application constants are not autoloadable from initializer
# bodies, and it must precede the application finisher that freezes UpdateCheck.
if ENV["TESTER_ENV_SKIP_REGISTRATION"] == "true"
  Rails.application.config.to_prepare do
    UpdateCheck.singleton_class.prepend(Module.new do
      def skip_http?
        true
      end
    end)
  end
end
