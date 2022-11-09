#
# Spring Boot Packager
#
# See the macro documentation below for details.

# Spring Boot Executable JAR Layout specification
#   reverse engineered from the Spring Boot maven plugin

# /
# /META-INF/
# /META-INF/MANIFEST.MF                        <-- very specific manifest for Spring Boot (generated by this rule)
# /BOOT-INF
# /BOOT-INF/classes
# /BOOT-INF/classes/git.properties             <-- properties file containing details of the current source tree via Git
# /BOOT-INF/classes/**/*.class                 <-- compiled application classes, must include @SpringBootApplication class
# /BOOT-INF/classes/META-INF/*                 <-- application level META-INF config files (e.g. spring.factories)
# /BOOT-INF/lib
# /BOOT-INF/lib/*.jar                          <-- all upstream transitive dependency jars must be here (except spring-boot-loader)
# /org/springframework/boot/loader
# /org/springframework/boot/loader/**/*.class  <-- the Spring Boot Loader classes must be here

# ***************************************************************
# Dependency Aggregator Rule
#  do not use directly, see the SpringBoot Macro below

def _depaggregator_rule_impl(ctx):
    # magical incantation for getting upstream transitive closure of java deps
    merged = java_common.merge([dep[java_common.provider] for dep in ctx.attr.deps])
    jars = merged.transitive_runtime_jars

    # print("AGGREGATED DEPS")
    # print(jars)

    return [DefaultInfo(files = jars)]

_depaggregator_rule = rule(
    implementation = _depaggregator_rule_impl,
    attrs = {
        "depaggregator_rule": attr.label(),
        "deps": attr.label_list(providers = [java_common.provider]),
    },
)

# ***************************************************************
# Entry point script for "bazel run"

_run_script_template = """
#!/bin/bash

# should (can?) we use one of the jdk locations already known to Bazel?
if [ -z ${JAVA_HOME} ]; then
  java_cmd="$(which java)"
else
  java_cmd="${JAVA_HOME}/bin/java"
fi

if [ -z "${java_cmd}" ]; then
  echo "ERROR: no java found, either set JAVA_HOME or add the java executable to your PATH"
  exit 1
fi

echo "Using Java at ${java_cmd}"
${java_cmd} -version
echo ""

path=%path%
jar=%jar%

cmd="${java_cmd} ${JAVA_OPTS} -jar ${path}/${jar} ${MAIN_ARGS}"
echo "Running ${cmd}"
echo "In directory $(pwd)"
echo ""
echo "You can also run from the root of the repo:"
echo "java -jar bazel-bin/${path}/${jar}"
echo ""

${cmd}
"""

# ***************************************************************
# SpringBoot Rule
#  do not use directly, see the SpringBoot Macro below

def _springboot_rule_impl(ctx):
    outs = depset(transitive = [
        ctx.attr.app_compile_rule.files,
        ctx.attr.genmanifest_rule.files,
        ctx.attr.gengitinfo_rule.files,
        ctx.attr.genjar_rule.files,
    ])

    # setup the script that runs "java -jar <springboot.jar>" when calling
    # "bazel run" with the springboot target
    script = _run_script_template \
        .replace("%path%", ctx.label.package) \
        .replace("%jar%", _get_springboot_jar_file_name(str(ctx.label.name)))

    script_out = ctx.actions.declare_file("%s-run" % ctx.label.name)
    ctx.actions.write(script_out, script, is_executable = True)

    # the jar we build needs to be part of runfiles so that it ends up in the
    # working directory that "bazel run" uses
    runfiles = ctx.runfiles(files = ctx.attr.genjar_rule.files.to_list())
    return [DefaultInfo(
        files = outs,
        executable = script_out,
        runfiles = runfiles,
    )]

_springboot_rule = rule(
    implementation = _springboot_rule_impl,
    executable = True,
    attrs = {
        "app_compile_rule": attr.label(),
        "dep_aggregator_rule": attr.label(),
        "genmanifest_rule": attr.label(),
        "gengitinfo_rule": attr.label(),
        "genjar_rule": attr.label(),
        "apprun_rule": attr.label(),
        "deps": attr.label_list(providers = [java_common.provider]),
    },
)

# ***************************************************************
# SpringBoot Macro
#  invoke this from your BUILD file
#
#  name:    name of your application
#  boot_app_class:  the classname (java package+type) of the @SpringBootApplication class in your app
#  deps:  the array of upstream dependencies
#  fail_on_duplicated_classes:  if enabled, ensures that the final spring boot jar does not contain any duplicate classes (also checks nested jars)
#  tags:  the array of optional tags to apply to this rule and subrules
def springboot(name, java_library, boot_app_class, deps, fail_on_duplicate_classes = False, tags = []):
    # Create the subrule names
    dep_aggregator_rule = native.package_name() + "_deps"
    genmanifest_rule = native.package_name() + "_genmanifest"
    gengitinfo_rule = native.package_name() + "_gengitinfo"
    genjar_rule = native.package_name() + "_genjar"
    apprun_rule = native.package_name() + "_apprun"

    # SUBRULE 1: AGGREGATE UPSTREAM DEPS
    #  Aggregate transitive closure of upstream Java deps
    _depaggregator_rule(
        name = dep_aggregator_rule,
        deps = deps,
    )

    # SUBRULE 2: GENERATE THE MANIFEST
    #  NICER: derive the Build JDK and Boot Version values by scanning transitive deps
    genmanifest_out = "MANIFEST.MF"
    native.genrule(
        name = genmanifest_rule,
        srcs = [":" + dep_aggregator_rule],
        cmd = "$(location //tools/springboot:write_manifest.sh) " + boot_app_class + " $@ $(SRCS)",
        #      message = "SpringBoot rule is writing the MANIFEST.MF...",
        tools = ["//tools/springboot:write_manifest.sh"],
        outs = [genmanifest_out],
        tags = tags,
    )

    # SUBRULE 2B: GENERATE THE GIT PROPERTIES
    gengitinfo_out = "git.properties"
    native.genrule(
        name = gengitinfo_rule,
        cmd = "$(location //tools/springboot:write_gitinfo_properties.sh) $@",
        tools = ["//tools/springboot:write_gitinfo_properties.sh"],
        outs = [gengitinfo_out],
        tags = tags,
        stamp = 1,
    )

    verify_str = "dont_verify"
    if fail_on_duplicate_classes:
        verify_str = "verify"

    # SUBRULE 3: INVOKE THE BASH SCRIPT THAT DOES THE PACKAGING
    # The resolved input_file_paths array is made available as the $(SRCS) token in the cmd string.
    # Skylark will convert the logical input_file_paths into real file system paths when surfaced in $(SRCS)
    #  cmd format (see springboot_pkg.sh)
    #    param0: location of the jar utility (singlejar)
    #    param1: boot application classname (the @SpringBootApplication class)
    #    param2: verify_duplicates
    #    param3: jdk path for running java tools e.g. jar; $(JAVABASE)
    #    param4: executable jar output filename to write to
    #    param5: compiled application jar; $@
    #    param6: manifest file
    #    param7: git.properties file
    #    param8-N: upstream transitive dependency jar(s)
    native.genrule(
        name = genjar_rule,
        srcs = [java_library, ":" + genmanifest_rule, ":" + gengitinfo_rule, ":" + dep_aggregator_rule],
        cmd = "$(location //tools/springboot:springboot_pkg.sh) " +
              "$(location @bazel_tools//tools/jdk:singlejar) " +
              boot_app_class + " " + verify_str + " $(JAVABASE) " + name + " $@ $(SRCS)",
        tools = [
            "//tools/springboot:springboot_pkg.sh",
            "//tools/springboot:verify_conflict.py",
            "//tools/springboot:whitelist.txt",
            "@bazel_tools//tools/jdk:singlejar",
        ],
        tags = tags,
        outs = [_get_springboot_jar_file_name(name)],
        toolchains = ["@bazel_tools//tools/jdk:current_host_java_runtime"],  # so that JAVABASE is computed
    )

    # SUBRULE 4: PROVIDE A WELL KNOWN RUNNABLE RULE TYPE FOR IDE SUPPORT
    # The presence of this rule  makes a Spring Boot entry point class runnable
    # in IntelliJ (it won't run as part of a packaged Spring Boot jar, ie this
    # won't run java -jar springboot.jar, but close enough)
    # Making the springboot rule itself executable is not recognized by IntelliJ
    # (because IntelliJ doesn't know how to handle the springboot rule type or
    # because of a misconfiguration on our end?)
    native.java_binary(
        name = apprun_rule,
        main_class = boot_app_class,
        runtime_deps = [java_library] + deps,
        tags = tags,
    )

    # MASTER RULE: Create the composite rule that will aggregate the outputs of the subrules
    _springboot_rule(
        name = name,
        app_compile_rule = java_library,
        dep_aggregator_rule = ":" + dep_aggregator_rule,
        genmanifest_rule = ":" + genmanifest_rule,
        gengitinfo_rule = ":" + gengitinfo_rule,
        genjar_rule = ":" + genjar_rule,
        apprun_rule = ":" + apprun_rule,
        deps = deps,
        tags = tags,
    )

# end springboot macro

# Simple wrapper around java_test that adds a data dependency on the calling project's springboot JAR file.
def springboot_test(**kwargs):
    springboot_jar_data = [native.package_name() + "_genjar"]
    if ("data" in kwargs):
        kwargs["data"] += springboot_jar_data
    else:
        kwargs["data"] = springboot_jar_data
    native.java_test(**kwargs)

def _get_springboot_jar_file_name(name):
    if name.endswith(".jar"):
        fail("the name attribute of the springboot rule should not end with '.jar'")
    return name + ".jar"
