
ifeq ($(V),)
	quiet	= quiet_
	Q	= @
else
	quiet	=
	Q	=
endif

echo-cmd = $(if $($(quiet)cmd_$(1)),\
	echo "  $($(quiet)cmd_$(1))";)

cmd = @$(echo-cmd) $(cmd_$(1))
