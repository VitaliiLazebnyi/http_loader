# Reproduces the CI/Linux environment for http_loader, including the native /proc
# resource-monitoring code paths that cannot be exercised on macOS. The full ruby image
# (not -slim) is used deliberately: it already ships the toolchain the native gem
# extensions (io-event and friends) compile against, so no apt layer is needed.
# Pinned by digest to the newest 4.0.9 release; `rake outdated` and Dependabot flag drift.
FROM ruby:4.0.9@sha256:69af6414ff991a513b535b162735b5177b381f7e4a08045b48e5a707d144cd57

# BUNDLE_PATH keeps gems inside the project tree; CI=true turns on the 100% coverage gate.
ENV LANG=C.UTF-8 \
    BUNDLE_PATH=/app/vendor/bundle \
    CI=true

WORKDIR /app

# Install dependencies in a cacheable layer keyed only on the gem manifests, so editing
# lib/spec files does not trigger a full re-bundle on every rebuild. The bundler version
# matches the Gemfile.lock "BUNDLED WITH" pin.
COPY Gemfile Gemfile.lock http_loader.gemspec ./
COPY lib/http_loader/version.rb lib/http_loader/version.rb
RUN gem install bundler:4.0.20 --no-document \
 && bundle install

COPY . .

# Default: run the full local verification gate (specs + coverage, rubocop, suppressions,
# Sorbet, YARD, Reek, Flay, bundler-audit).
CMD ["bundle", "exec", "rake"]
