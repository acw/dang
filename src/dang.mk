
dang_sources := \
	src/CodeGen.hs \
	src/Colors.hs \
	src/Compile.hs \
	src/Compile/LambdaLift.hs \
	src/Compile/Rename.hs \
	src/Core/AST.hs \
	src/Core/Interface.hs \
	src/Dang/FileName.hs \
	src/Dang/IO.hs \
	src/Dang/Monad.hs \
	src/Dang/Tool.hs \
	src/Data/ClashMap.hs \
	src/Link.hs \
	src/Main.hs \
	src/ModuleSystem.hs \
	src/ModuleSystem/Export.hs \
	src/ModuleSystem/Imports.hs \
	src/ModuleSystem/Interface.hs \
	src/ModuleSystem/Resolve.hs \
	src/ModuleSystem/ScopeCheck.hs \
	src/ModuleSystem/Types.hs \
	src/Pretty.hs \
	src/Prim.hs \
	src/QualName.hs \
	src/ReadWrite.hs \
	src/Syntax.hs \
	src/Syntax/AST.hs \
	src/Syntax/Layout.hs \
	src/Syntax/Lexer.hs \
	src/Syntax/Lexeme.hs \
	src/Syntax/Parser.hs \
	src/Syntax/ParserCore.hs \
	src/Syntax/Quote.hs \
	src/Syntax/Renumber.hs \
	src/Traversal.hs \
	src/TypeChecker.hs \
	src/TypeChecker/CheckKinds.hs \
	src/TypeChecker/CheckTypes.hs \
	src/TypeChecker/Env.hs \
	src/TypeChecker/Monad.hs \
	src/TypeChecker/Quote.hs \
	src/TypeChecker/Types.hs \
	src/TypeChecker/Unify.hs \
	src/Utils.hs \
	src/Variables.hs

-include src/.depend

GHCFLAGS := -Wall -isrc -hidir src -odir src

src/.depend: SOURCES := $(dang_sources)
src/.depend: $(dang_sources)
	$(call cmd,hs_depend)

dang_objects    := $(dang_sources:.hs=.o)
dang_interfaces := $(dang_sources:.hs=.hi)

dang_packages := $(addprefix -package ,\
	array base bytestring cereal containers directory filepath GraphSCC \
	llvm-pretty monadLib pretty process syb template-haskell text)

build/bin/dang: HAPPYFLAGS := -g -i
build/bin/dang: ALEXFLAGS  := -g
build/bin/dang: GHCFLAGS   += -hide-all-packages $(dang_packages)
build/bin/dang: LDFLAGS    := -Wall -hide-all-packages $(dang_packages)
build/bin/dang: OBJECTS    := $(dang_objects)
build/bin/dang: $(dang_objects) | build/bin
	$(call cmd,link_hs)

all: build/bin/dang

clean::
	$Q$(RM) $(dang_objects) $(dang_interfaces)

mrproper::
	$Q$(RM) src/Syntax/Parser.hs src/Syntax/Lexer.hs
	$Q$(RM) src/.depend