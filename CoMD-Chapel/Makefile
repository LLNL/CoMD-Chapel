# --cache-remote -snoRefCount significantly speed up code with arrays
CHPL_FLAGS= --fast --cache-remote -snoRefCount -sdefaultDoRADOpt=true -sdisableAliasedBulkTransfer=false --conditional-dynamic-dispatch-limit=2

# This is extremely slow
#CHPL_FLAGS= --fast -sdefaultDoRADOpt=true -sdisableAliasedBulkTransfer=false --conditional-dynamic-dispatch-limit=2

SAVE_C_CODE= --savec ./c_code

md: rand.chpl types.chpl configs.chpl helpers.chpl setup.chpl force.chpl forcelj.chpl forceeam.chpl MD.chpl
	chpl $(CHPL_FLAGS) $(SAVE_C_CODE) $^ -o $@
clean:
	-@rm -vf md md_real *.o
