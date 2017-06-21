CHPL_FLAGS= --fast -suseBulkTransferStride -sdataParTasksPerLocale=5 -sdefaultDoRADOpt=true -sdisableAliasedBulkTransfer=false --conditional-dynamic-dispatch-limit=2
#CHPL_FLAGS= --fast --cache-remote -suseBulkTransferStride -sdataParTasksPerLocale=5 -sdefaultDoRADOpt=true -sdisableAliasedBulkTransfer=false --conditional-dynamic-dispatch-limit=2

SAVE_C_CODE= --savec ./c_code

md: rand.chpl types.chpl configs.chpl helpers.chpl setup.chpl force.chpl forcelj.chpl forceeam.chpl MD.chpl
	chpl $(CHPL_FLAGS) $(SAVE_C_CODE) $^ -o $@
clean:
	-@rm -vf md md_real *.o
