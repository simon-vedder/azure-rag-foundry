"""Regression tests for Aria's access-control contract (app/access.py).

These assert the security-critical properties of the topic model:
  1. Tiers are hierarchical and a lower tier never sees a higher one.
  2. A role for topic A can never grant access to topic B's content.
  3. The logic is tier-agnostic — it works for any configured, ordered tiers list.
If any breaks, the isolation guarantee is void — so these run as plain unit tests, no Azure.
"""

import base64
import json

import access

TOPICS = {"hr": "HR", "it": "IT"}
TIERS3 = ["public", "internal", "confidential"]
TIERS2 = ["public", "internal"]


def principal_header(roles):
    """Build an X-MS-CLIENT-PRINCIPAL value the way Easy Auth would for a user holding `roles`."""
    payload = {"claims": [{"typ": "roles", "val": r} for r in roles]}
    return base64.b64encode(json.dumps(payload).encode()).decode()


# ── parse_topics / parse_tiers / get_user_roles ────────────────────────────

def test_parse_topics_roundtrip():
    assert access.parse_topics(json.dumps(TOPICS)) == TOPICS


def test_parse_topics_bad_input_is_empty():
    assert access.parse_topics("") == {}
    assert access.parse_topics("not json") == {}


def test_parse_tiers_roundtrip_and_fallback():
    assert access.parse_tiers(json.dumps(TIERS3)) == TIERS3
    assert access.parse_tiers("") == access.DEFAULT_TIERS
    assert access.parse_tiers("garbage") == access.DEFAULT_TIERS


def test_get_user_roles_decodes_header():
    header = principal_header(["hr.Internal.Read", "it.Content.Admin"])
    assert access.get_user_roles(header) == {"hr.Internal.Read", "it.Content.Admin"}


def test_get_user_roles_missing_header_is_empty():
    assert access.get_user_roles("") == set()


# ── allowed_levels: tier hierarchy (3-tier) ────────────────────────────────

def test_no_roles_all_users_sees_base_tier():
    assert access.allowed_levels(set(), "hr", TIERS3, "all_users") == ["public"]


def test_no_roles_role_required_sees_nothing():
    assert access.allowed_levels(set(), "hr", TIERS3, "role_required") == []


def test_internal_reader_gets_public_and_internal_not_confidential():
    levels = access.allowed_levels({"hr.Internal.Read"}, "hr", TIERS3, "role_required")
    assert levels == ["public", "internal"]
    assert "confidential" not in levels


def test_confidential_reader_gets_all_tiers():
    assert access.allowed_levels({"hr.Confidential.Read"}, "hr", TIERS3, "role_required") == TIERS3


def test_content_admin_can_read_all_tiers():
    assert access.allowed_levels({"hr.Content.Admin"}, "hr", TIERS3, "role_required") == TIERS3


def test_public_read_role_only_grants_base_tier():
    assert access.allowed_levels({"hr.Public.Read"}, "hr", TIERS3, "role_required") == ["public"]


def test_levels_are_ordered_by_tiers_list():
    levels = access.allowed_levels({"hr.Confidential.Read"}, "hr", TIERS3, "all_users")
    assert levels == [t for t in TIERS3 if t in levels]


# ── Tier-agnostic: 2-tier deployment ───────────────────────────────────────

def test_two_tier_internal_reader_sees_everything_configured():
    # With only public+internal configured, Internal.Read is the top tier.
    assert access.allowed_levels({"hr.Internal.Read"}, "hr", TIERS2, "all_users") == ["public", "internal"]


def test_two_tier_has_no_confidential_concept():
    # A stray confidential role grants nothing when confidential isn't a configured tier.
    assert access.allowed_levels({"hr.Confidential.Read"}, "hr", TIERS2, "role_required") == []


def test_custom_tier_names():
    tiers = ["open", "restricted"]
    assert access.allowed_levels({"hr.Restricted.Read"}, "hr", tiers, "role_required") == ["open", "restricted"]
    assert access.allowed_levels(set(), "hr", tiers, "all_users") == ["open"]


def test_single_tier_topic_membership_model():
    tiers = ["public"]
    # all_users: everyone sees the one tier; admin still works.
    assert access.allowed_levels(set(), "hr", tiers, "all_users") == ["public"]
    assert access.allowed_levels({"hr.Content.Admin"}, "hr", tiers, "role_required") == ["public"]
    assert access.allowed_levels(set(), "hr", tiers, "role_required") == []


# ── Cross-topic isolation ──────────────────────────────────────────────────

def test_hr_role_grants_no_extra_access_to_it_role_required():
    roles = {"hr.Confidential.Read", "hr.Content.Admin"}
    assert access.allowed_levels(roles, "it", TIERS3, "role_required") == []
    assert access.build_search_filter(roles, "it", TIERS3, "role_required") is None


def test_hr_role_only_sees_it_base_tier_in_all_users_mode():
    assert access.allowed_levels({"hr.Confidential.Read"}, "it", TIERS3, "all_users") == ["public"]


def test_filter_is_always_scoped_to_one_topic():
    f = access.build_search_filter({"hr.Confidential.Read"}, "hr", TIERS3, "role_required")
    assert f.startswith("topic eq 'hr' and ")
    assert "topic eq 'it'" not in f


# ── build_search_filter: escalation blocked ────────────────────────────────

def test_internal_reader_filter_excludes_confidential():
    f = access.build_search_filter({"hr.Internal.Read"}, "hr", TIERS3, "role_required")
    assert "access_level eq 'public'" in f
    assert "access_level eq 'internal'" in f
    assert "confidential" not in f


def test_no_access_returns_none_filter():
    assert access.build_search_filter(set(), "hr", TIERS3, "role_required") is None


# ── accessible_topics / admin ──────────────────────────────────────────────

def test_accessible_topics_all_users_shows_everything():
    assert access.accessible_topics(set(), TOPICS, TIERS3, "all_users") == TOPICS


def test_accessible_topics_role_required_filters_to_held_roles():
    roles = {"hr.Internal.Read"}
    assert access.accessible_topics(roles, TOPICS, TIERS3, "role_required") == {"hr": "HR"}


def test_can_admin_topic_requires_content_admin():
    assert access.can_admin_topic({"hr.Content.Admin"}, "hr") is True
    assert access.can_admin_topic({"hr.Confidential.Read"}, "hr") is False
    assert access.can_admin_topic({"it.Content.Admin"}, "hr") is False


def test_admin_topics_filters_to_administered():
    roles = {"hr.Content.Admin", "it.Internal.Read"}
    assert access.admin_topics(roles, TOPICS) == {"hr": "HR"}
