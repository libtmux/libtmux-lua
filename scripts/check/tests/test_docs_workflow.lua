-- The docs workflow keeps its source, exporter and site in separate checkouts and publishes the
-- exact content it built.
local test = require("luaunit")
local files = require("support.files")
local repo = require("support.repo")
local M = {}

local WORKFLOW = files.read(repo.root .. "/.github/workflows/docs.yml")

local function has(text)
    test.assertNotNil(WORKFLOW:find(text, 1, true), "docs.yml lacks: " .. text)
end

local function position(text)
    return assert(WORKFLOW:find(text, 1, true), "docs.yml lacks: " .. text)
end

function M.test_preview_publication_uses_the_preview_role()
    has(
        "role-arn: ${{ matrix.environment == 'docs-preview' && "
            .. "secrets.LIBTMUX_DOCS_PREVIEW_ROLE_ARN || secrets.LIBTMUX_DOCS_ROLE_ARN }}"
    )
end

function M.test_source_exporter_and_docs_use_separate_checkouts()
    for _, name in ipairs({ "port", "docs-generator", "docs" }) do
        has("          path: " .. name .. "\n")
    end
    test.assertNil(WORKFLOW:find("path: .site", 1, true))
    test.assertNil(WORKFLOW:find("path: .docs-generator", 1, true))
    has("LIBTMUX_DOCS_CHECKOUT_LUA: ${{ github.workspace }}/port")
    has("LIBTMUX_DOCS_GENERATOR_CHECKOUT: ${{ github.workspace }}/docs-generator")
    test.assertTrue(
        position("publication-provenance.mjs snapshot")
            < position("Bootstrap the pinned LuaLS exporter")
    )
    has('--source "$GITHUB_WORKSPACE/port"')
    has('--output "$GITHUB_WORKSPACE/port/docs/_build"')
    has("LIBTMUX_DOCS_INPUT_SNAPSHOT: ${{ runner.temp }}/build-inputs.json")
end

function M.test_descriptor_uses_the_exact_content_upload()
    has("      - id: content\n        uses: actions/upload-artifact@")
    has("include-hidden-files: true")
    has("ARTIFACT_ID: ${{ steps.content.outputs.artifact-id }}")
    has("ARTIFACT_DIGEST: ${{ steps.content.outputs.artifact-digest }}")
    has("ARTIFACT_NAME: docs-lua-${{ matrix.version }}")
    has("name: docs-lua-${{ matrix.version }}-publication")
    has('publication-provenance.mjs descriptor "$RUNNER_TEMP/publication.json"')
    local sha = WORKFLOW:match("repository: libtmux/docs\n%s+ref: (%x+)")
    test.assertNotNil(sha)
    test.assertEquals(#sha, 40)
    has("reusable-deploy.yml@" .. sha)
end

function M.test_arbitrary_source_builds_do_not_restore_caches()
    has("working_directory: port\n          cache: false")
    test.assertNil(WORKFLOW:find("cache: pnpm", 1, true))
end

function M.test_the_exporter_runs_on_the_tool_luajit_the_workflow_builds()
    has("lua scripts/bootstrap/bootstrap.lua runtimes luajit")
    has(".cache/toolchains/luajit-2.1/bin/luajit scripts/docs/docs.lua export")
    test.assertNil(WORKFLOW:find("python", 1, true))
end

return M
