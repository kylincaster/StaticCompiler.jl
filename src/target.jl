"""
```julia
    StaticTarget() # Native target
    StaticTarget(platform::Base.BinaryPlatforms.Platform) # Specific target with generic CPU
    StaticTarget(platform::Platform, cpu::String) # Specific target with specific CPU
    StaticTarget(platform::Platform, cpu::String, features::String) # Specific target with specific CPU and features
```
Struct that defines a target for the compilation
Beware that currently the compilation assumes that the code is on the host so platform specific code like:
```julia
    Sys.isapple() ...
```
does not behave as expected.
By default `StaticTarget()` is the native target.

For cross-compilation of executables and shared libraries, one also needs to call `set_compiler!` with the path to a valid C compiler
for the target platform. For example, to cross-compile for aarch64 using a compiler from homebrew, one can use:
```julia
    set_compiler!(StaticTarget(parse(Platform,"aarch64-gnu-linux")), "/opt/homebrew/bin/aarch64-unknown-linux-gnu-gcc")
```
"""
mutable struct StaticTarget
    platform::Union{Platform,Nothing}
    tm::LLVM.TargetMachine
    compiler::Union{String,Nothing}
    julia_runtime::Bool
end

clean_triple(platform::Platform) = arch(platform) * os_str(platform) * libc_str(platform)
StaticTarget() = StaticTarget(HostPlatform(), unsafe_string(LLVM.API.LLVMGetHostCPUName()), unsafe_string(LLVM.API.LLVMGetHostCPUFeatures()))
StaticTarget(platform::Platform) = StaticTarget(platform, LLVM.TargetMachine(LLVM.Target(triple = clean_triple(platform)), clean_triple(platform)), nothing, false)
StaticTarget(platform::Platform, cpu::String) = StaticTarget(platform, LLVM.TargetMachine(LLVM.Target(triple = clean_triple(platform)), clean_triple(platform), cpu), nothing, false)
StaticTarget(platform::Platform, cpu::String, features::String) = StaticTarget(platform, LLVM.TargetMachine(LLVM.Target(triple = clean_triple(platform)), clean_triple(platform), cpu, features), nothing, false)

function StaticTarget(triple::String, cpu::String, features::String)
    platform = tryparse(Platform, triple)
    StaticTarget(platform, LLVM.TargetMachine(LLVM.Target(triple = triple), triple, cpu, features), nothing)
end

"""
Set the compiler for cross compilation
    ```julia
    set_compiler!(StaticTarget(parse(Platform,"aarch64-gnu-linux")), "/opt/homebrew/bin/aarch64-elf-gcc")
```
"""
set_compiler!(target::StaticTarget, compiler::String) = (target.compiler = compiler)


set_runtime!(target::StaticTarget, julia_runtime::Bool) = (target.julia_runtime = julia_runtime)

# Default to native
struct StaticCompilerTarget{MT} <: GPUCompiler.AbstractCompilerTarget
    triple::String
    cpu::String
    features::String
    julia_runtime::Bool
    method_table::MT
end

module StaticRuntime
    # the runtime library
    signal_exception() = return
    malloc(sz) = ccall("extern malloc", llvmcall, Csize_t, (Csize_t,), sz)
    report_oom(sz) = return
    report_exception(ex) = return
    report_exception_name(ex) = return
    report_exception_frame(idx, func, file, line) = return
end


GPUCompiler.llvm_triple(target::StaticCompilerTarget) = target.triple

function GPUCompiler.llvm_machine(target::StaticCompilerTarget)
    triple = GPUCompiler.llvm_triple(target)

    t = LLVM.Target(triple=triple)

    tm = LLVM.TargetMachine(t, triple, target.cpu, target.features, reloc=LLVM.API.LLVMRelocPIC)
    GPUCompiler.asm_verbosity!(tm, true)

    return tm
end

GPUCompiler.runtime_slug(job::GPUCompiler.CompilerJob{<:StaticCompilerTarget}) = "static_$(job.config.target.cpu)-$(hash(job.config.target.features))"

GPUCompiler.runtime_module(::GPUCompiler.CompilerJob{<:StaticCompilerTarget}) = StaticRuntime
GPUCompiler.runtime_module(::GPUCompiler.CompilerJob{<:StaticCompilerTarget, StaticCompilerParams}) = StaticRuntime


GPUCompiler.can_throw(job::GPUCompiler.CompilerJob{<:StaticCompilerTarget, StaticCompilerParams}) = true
GPUCompiler.can_throw(job::GPUCompiler.CompilerJob{<:StaticCompilerTarget}) = true

GPUCompiler.uses_julia_runtime(job::GPUCompiler.CompilerJob{<:StaticCompilerTarget}) = job.config.target.julia_runtime
@static if HAS_INTEGRATED_CACHE
    GPUCompiler.get_interpreter(job::GPUCompiler.CompilerJob{<:StaticCompilerTarget, StaticCompilerParams}) =
        StaticInterpreter(job.world, GPUCompiler.method_table(job), GPUCompiler.ci_cache_token(job), inference_params(job), optimization_params(job))
else
    GPUCompiler.ci_cache(job::GPUCompiler.CompilerJob{<:StaticCompilerTarget, StaticCompilerParams}) = job.config.params.cache
    GPUCompiler.get_interpreter(job::GPUCompiler.CompilerJob{<:StaticCompilerTarget, StaticCompilerParams}) =
        StaticInterpreter(job.world, GPUCompiler.method_table(job), job.config.params.cache, inference_params(job), optimization_params(job))
end
GPUCompiler.method_table(@nospecialize(job::GPUCompiler.CompilerJob{<:StaticCompilerTarget})) = job.config.target.method_table


function static_job(@nospecialize(func), @nospecialize(types);
    name = fix_name(func),
    kernel::Bool = false,
    target::StaticTarget = StaticTarget(),
    method_table=method_table,
    kwargs...
)
    source = methodinstance(typeof(func), Base.to_tuple_type(types))
    tm = target.tm
    gputarget = StaticCompilerTarget(LLVM.triple(tm), LLVM.cpu(tm), LLVM.features(tm), target.julia_runtime, method_table)
    params = StaticCompilerParams()
    @static if pkgversion(GPUCompiler) < v"1"
        config = GPUCompiler.CompilerConfig(gputarget, params; name = name, kernel = kernel)
        return StaticCompiler.CompilerJob(source, config), kwargs
    else
        config = GPUCompiler.CompilerConfig(gputarget, params; name = name, kernel = kernel, kwargs...)
        return StaticCompiler.CompilerJob(source, config), Dict{}()
    end
end