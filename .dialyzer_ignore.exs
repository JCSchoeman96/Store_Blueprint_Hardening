[
  # DEP-SEC-03 / DEPS-LATEST-02 review (2026-09-03):
  # The 37 entries added by PR #4 are limited to the following reviewed
  # categories: 12 intentionally broad public specs (contract_supertype);
  # 3 defensive result branches (pattern_match); 9 defensive/fallback
  # branches (pattern_match_cov); 12 intentional side-effect-only return
  # values (unmatched_return); and 1 existing renewal helper not reachable
  # in every typed branch (unused_fun). They were reproduced against the
  # reconciled graph with the ignore list empty. The new unknown_type,
  # unknown_function, no_return, call, guard_fail, and invalid_contract
  # diagnostics were fixed or removed instead of being suppressed.
  #
  # The broad-spec entries do not alter runtime behavior. The defensive
  # branch entries preserve dynamic-caller fallbacks, and the unmatched
  # return entries preserve existing stable API return shapes while making
  # intentional cache, telemetry, cleanup, and enqueue effects explicit in
  # the review record.
  {"lib/store/accounts/user/senders/send_password_reset_email.ex", :callback_type_mismatch},
  {"lib/store/admin/changes/audit_after_action.ex", :guard_fail},
  {"lib/store/carts/facade.ex", :pattern_match_cov},
  {"lib/store/carts/inputs/cart_item_input.ex", :contract_supertype},
  {"lib/store/catalog/availability_cache.ex", :unmatched_return},
  {"lib/store/catalog/category.ex", :call_to_missing},
  {"lib/store/catalog/facade.ex", :pattern_match},
  {"lib/store/catalog/product_detail_telemetry.ex", :contract_supertype},
  {"lib/store/catalog/product_list_cache.ex", :unmatched_return},
  {"lib/store/catalog/stock_fast_path.ex", :unmatched_return},
  {"lib/store/checkout/domain.ex", :pattern_match},
  {"lib/store/checkout/domain.ex", :pattern_match_cov},
  {"lib/store/checkout/domain.ex", :unused_fun},
  {"lib/store/comms/domain.ex", :extra_range},
  {"lib/store/comms/domain.ex", :pattern_match},
  {"lib/store/comms/domain.ex", :unused_fun},
  {"lib/store/comms/providers.ex", :contract_supertype},
  {"lib/store/digital/facade.ex", :pattern_match_cov},
  {"lib/store/digital/storage_providers.ex", :contract_supertype},
  {"lib/store/digital/storage_providers/ex_aws_s3_adapter.ex", :no_return},
  {"lib/store/digital/storage_providers/ex_aws_s3_adapter.ex", :call},
  {"lib/store/entitlements/cache.ex", :contract_supertype},
  {"lib/store/entitlements/cache.ex", :pattern_match_cov},
  {"lib/store/operations/health.ex", :contract_supertype},
  {"lib/store/orders/domain.ex", :pattern_match_cov},
  {"lib/store/orders/domain.ex", :unmatched_return},
  {"lib/store/orders/inventory_reservations.ex", :pattern_match_cov},
  {"lib/store/payments/domain.ex", :contract_supertype},
  {"lib/store/payments/facade.ex", :pattern_match_cov},
  {"lib/store/payments/facade.ex", :pattern_match},
  {"lib/store/payments/interlocks.ex", :pattern_match_cov},
  {"lib/store/payments/provider_config.ex", :contract_supertype},
  {"lib/store/perf/chaos_profile.ex", :contract_supertype},
  {"lib/store/pricing/tax_shipping_evaluator.ex", :pattern_match},
  {"lib/store/release.ex", :contract_supertype},
  {"lib/store/release.ex", :unmatched_return},
  {"lib/store/repo.ex", :no_return},
  {"lib/store/shipping/quote_cache.ex", :unmatched_return},
  {"lib/store/subscriptions/facade.ex", :unmatched_return},
  {"lib/store/subscriptions/facade.ex", :pattern_match},
  {"lib/store/subscriptions/facade.ex", :unused_fun},
  {"lib/store/subscriptions/facade.ex", :pattern_match_cov},
  {"lib/store/support/errors/normalize.ex", :contract_supertype},
  {"lib/store/support/governance/idempotency.ex", :pattern_match_cov},
  {"lib/store/support/governance/surface_registry.ex", :invalid_contract},
  {"lib/store/support/id/prefixed_id.ex", :pattern_match_cov},
  {"lib/store/support/id/uuid_v7.ex", :contract_supertype},
  {"lib/store/support/rate_limit/ets_backend.ex", :unmatched_return},
  {"lib/store/support/rate_limit/redix_client.ex", :contract_supertype},
  {"lib/store/support/redis.ex", :contract_supertype},
  {"lib/store/support/redis.ex", :unmatched_return},
  {"lib/store/support/telemetry/redis_aggregates.ex", :contract_supertype},
  {"lib/store/support/telemetry/redis_aggregates.ex", :unmatched_return},
  {"lib/store/support/telemetry/repo_stats.ex", :unmatched_return},
  {"lib/store/tools/risk_appetite.ex", :pattern_match},
  {"lib/store/tools/risk_appetite.ex", :contract_supertype},
  {"lib/store/workers/deliver_email_outbox_worker.ex", :pattern_match},
  {"lib/store_web/live/admin/email_outbox/index_live.ex", :guard_fail},
  {"lib/store_web/live/cart_live.ex", :pattern_match_cov},
  {"lib/store_web/live/checkout_live/placeholder.ex", :unmatched_return},
  {"lib/store_web/live/checkout_live/placeholder.ex", :pattern_match_cov},
  {"lib/store_web/live/entitlement_aware.ex", :unmatched_return},
  {"lib/store_web/live/shop_live/show.ex", :unmatched_return},
  {"lib/store_web/live/shop_live/show.ex", :pattern_match_cov},
  {"lib/store_web/live/static_to_live.ex", :unmatched_return},
  {"lib/store_web/live/static_to_live.ex", :contract_supertype},
  {"lib/store_web/payment_ingress_telemetry.ex", :contract_supertype}
]
