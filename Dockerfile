# Reproduces the CI/Linux environment for http_loader, including the native /proc
# resource-monitoring code paths that cannot be exercised on macOS.
FROM ruby:4.0.2

# procps -> `ps`; lsof for the non-/proc fallback path; getconf ships in libc-bin.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends procps lsof \
 && rm -rf /var/lib/apt/lists/*

# BUNDLE_PATH mirrors the committed .bundle/config (vendor/bundle) so Sorbet walks the
# gem RBIs exactly as CI does (the prism shim depends on this). CI=true enables the
# 100% coverage gate for full-suite runs.
ENV LANG=C.UTF-8 \
    BUNDLE_PATH=/app/vendor/bundle \
    CI=true

WORKDIR /app

# Install dependencies in a cacheable layer keyed only on the gem manifests, so that
# editing lib/spec files does not trigger a full re-bundle on every rebuild.
COPY Gemfile Gemfile.lock http_loader.gemspec ./
COPY lib/http_loader/version.rb lib/http_loader/version.rb
RUN gem install bundler:4.0.10 \
 && bundle install

COPY . .

# Default: run the full CI gate (specs + coverage, rubocop, strong Sorbet, yard, gem build).
CMD ["bundle", "exec", "rake", "ci"]
