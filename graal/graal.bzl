load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "ASSEMBLE_ACTION_NAME",
    "CPP_COMPILE_ACTION_NAME",
    "CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME",
    "CPP_LINK_EXECUTABLE_ACTION_NAME",
    "CPP_LINK_STATIC_LIBRARY_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
    "OBJCPP_COMPILE_ACTION_NAME",
    "OBJC_COMPILE_ACTION_NAME",
)

def _graal_binary_implementation(ctx):
    graal_attr = ctx.attr._graal
    graal_inputs, _, _ = ctx.resolve_command(tools = [graal_attr])
    graal = graal_inputs[0]

    classpath_depset = depset(transitive = [
        dep[JavaInfo].transitive_runtime_jars
        for dep in ctx.attr.deps
        if JavaInfo in dep
    ])

    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    if ctx.attr.c_compiler_path != None and len(ctx.attr.c_compiler_path) > 0:
        c_compiler_path = ctx.attr.c_compiler_path
    else:
        c_compiler_path = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = C_COMPILE_ACTION_NAME,
        )
    ld_executable_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
    )
    ld_static_lib_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
    )
    ld_dynamic_lib_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
    )

    tool_paths = [c_compiler_path, ld_executable_path, ld_static_lib_path, ld_dynamic_lib_path]
    path_set = {}
    for tool_path in tool_paths:
        tool_dir, _, _ = tool_path.rpartition("/")
        path_set[tool_dir] = None

    paths = sorted(path_set.keys())
    if ctx.configuration.host_path_separator == ":":
        # HACK: ":" is a proxy for a UNIX-like host.
        # The tools returned above may be bash scripts that reference commands
        # in directories we might not otherwise include. For example,
        # on macOS, wrapped_ar calls dirname.
        if "/bin" not in path_set:
            paths.append("/bin")
            if "/usr/bin" not in path_set:
                paths.append("/usr/bin")
    env = {}
    env["PATH"] = ctx.configuration.host_path_separator.join(paths)

    args = ctx.actions.args()
    args.add("--no-server")
    args.add("-cp", ":".join([f.path for f in classpath_depset.to_list()]))
    args.add("-H:Class=%s" % ctx.attr.main_class)
    args.add("-H:Name=%s" % ctx.outputs.bin.path)
    args.add("-H:CCompilerPath=%s" % c_compiler_path)

    configsets = []
    if len(ctx.attr.configsets) > 0:
        for configset in ctx.attr.configsets:
            config_files = configset.files.to_list()

            # verify expected number of config files per group (4)
            if len(config_files) > 4 or len(config_files) < 4:
                fail("Must specify exactly 4 files per native binary configset.")

            # verify that all config files in each group reside in the same directory
            dirname = config_files[0].dirname
            for file in config_files:
                if file.dirname != dirname:
                    fail("All native binary config files must reside in the same directory.")
                configsets.append(file)

            args.add("-H:ConfigurationResourceRoots=%s" % dirname)

    if len(ctx.attr.native_image_features) > 0:
        args.add("-H:Features={entries}".format(entries=",".join(ctx.attr.native_image_features)))

    if len(ctx.attr.initialize_at_build_time) > 0:
        args.add("--initialize-at-build-time={entries}".format(entries=",".join(ctx.attr.initialize_at_build_time)))

    if ctx.attr.reflection_configuration != None:
        args.add("-H:ReflectionConfigurationFiles={path}".format(path=ctx.file.reflection_configuration.path))
        input_depset = depset([ctx.file.reflection_configuration] + configsets, transitive=[classpath_depset])
    else:
        input_depset = depset(configsets)

    if ctx.attr.debug:
        args.add("-H:+ReportExceptionStackTraces")

    if ctx.attr.extra_args != None:
        for arg in ctx.attr.extra_args:
            args.add(arg)

    ctx.actions.run(
        inputs = input_depset,
        outputs = [ctx.outputs.bin],
        arguments = [args],
        executable = graal,
        env = env,
    )

    return [DefaultInfo(
        executable = ctx.outputs.bin,
        files = depset(),
        runfiles = ctx.runfiles(
            collect_data = True,
            collect_default = True,
            files = [],
        ),
    )]

graal_binary = rule(
    implementation = _graal_binary_implementation,
    attrs = {
        "deps": attr.label_list(
            allow_files = True,
        ),
        "configsets": attr.label_list(
            allow_files = True,
        ),
        "debug": attr.bool(),
        "c_compiler_path": attr.string(),
        "extra_args": attr.string_list(),
        "reflection_configuration": attr.label(mandatory=False, allow_single_file=True),
        "main_class": attr.string(),
        "initialize_at_build_time": attr.string_list(),
        "native_image_features": attr.string_list(),
        "_graal": attr.label(
            cfg = "host",
            default = "@graal//:bin/native-image",
            allow_files = True,
            executable = True,
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")
        ),
        "data": attr.label_list(allow_files = True),
    },
    outputs = {
        "bin": "%{name}-bin",
    },
    executable = True,
    fragments = ["cpp"],
)
