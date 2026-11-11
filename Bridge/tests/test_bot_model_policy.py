from hermes_bridge.policy import is_bot_model_configure_allowed

GOOD_MODEL = {"name": "bot-a", "model": "model-x", "provider": "provider-y"}


def test_only_explicit_profile_model_changes_are_allowed():
    assert is_bot_model_configure_allowed(GOOD_MODEL)
    assert is_bot_model_configure_allowed({**GOOD_MODEL, "confirm_expensive_model": True})
    for bad in ({**GOOD_MODEL, "enabled_toolsets": ["web"]}, {**GOOD_MODEL, "name": ""},
                {**GOOD_MODEL, "provider": " "}, {**GOOD_MODEL, "confirm_expensive_model": "true"},
                {**GOOD_MODEL, "model": ["x"]}, None):
        assert not is_bot_model_configure_allowed(bad)


def test_description_alone_is_allowed():
    assert is_bot_model_configure_allowed({"name": "assistant", "description": "Lead Developer of Example Labs"})


def test_empty_description_is_allowed_so_it_can_be_cleared():
    assert is_bot_model_configure_allowed({"name": "assistant", "description": ""})


def test_description_may_travel_with_a_model_change():
    assert is_bot_model_configure_allowed({
        **GOOD_MODEL, "description": "Lead Developer", "confirm_expensive_model": False,
    })


def test_description_must_be_a_string():
    for bad in ({"name": "assistant", "description": None},
                {"name": "assistant", "description": ["Lead Developer"]},
                {"name": "assistant", "description": {"text": "Lead Developer"}},
                {"name": "assistant", "description": 7}):
        assert not is_bot_model_configure_allowed(bad)


def test_soul_is_editable_from_the_app_within_a_ceiling():
    """SOUL.md is injected into every turn of that bot, so it is text with a hard size limit."""
    assert is_bot_model_configure_allowed({"name": "assistant", "soul": "# Soul\nLead developer."})
    assert is_bot_model_configure_allowed({"name": "assistant", "soul": ""})
    assert is_bot_model_configure_allowed({"name": "assistant", "description": "Lead", "soul": "x" * 64_000})
    assert not is_bot_model_configure_allowed({"name": "assistant", "soul": "x" * 64_001})
    assert not is_bot_model_configure_allowed({"name": "assistant", "soul": None})
    assert not is_bot_model_configure_allowed({"name": "assistant", "soul": ["x"]})


def test_description_does_not_open_the_other_sections():
    # `disabled_skills` and `enabled_mcp_servers` are deliberately not in this list any more: the app's
    # Skills and MCP panels write them, as validated name lists (see test_feature_toggle_policy.py).
    for bad in ({"name": "assistant", "description": "Lead Developer", "ui_meta": {}},
                {"name": "assistant", "description": "Lead Developer", "enabled_toolsets": []}):
        assert not is_bot_model_configure_allowed(bad)


def test_description_still_requires_a_name():
    assert not is_bot_model_configure_allowed({"description": "Lead Developer"})
    assert not is_bot_model_configure_allowed({"name": "  ", "description": "Lead Developer"})
    assert not is_bot_model_configure_allowed({"name": "assistant"})


def test_model_pair_must_be_complete_even_beside_a_description():
    assert not is_bot_model_configure_allowed(
        {"name": "assistant", "model": "model-x", "description": "Lead Developer"})
    assert not is_bot_model_configure_allowed(
        {"name": "assistant", "provider": "provider-y", "description": "Lead Developer"})


def test_confirmation_is_refused_without_a_model_change():
    assert not is_bot_model_configure_allowed(
        {"name": "assistant", "description": "Lead Developer", "confirm_expensive_model": True})
