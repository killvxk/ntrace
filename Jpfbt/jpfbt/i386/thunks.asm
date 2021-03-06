;----------------------------------------------------------------------
; Purpose:
;		Function entry/exit thunks.
;
; Copyright:
;		Johannes Passing (johannes.passing@googlemail.com)
;

 .586                                   ; create 32 bit code
.model flat, stdcall                    ; 32 bit memory model
option casemap :none                    ; case sensitive

extrn JpfbtpGetCurrentThunkStack@0 : proc
extrn JpfbtpProcedureEntry@8 : proc
extrn JpfbtpProcedureExit@8 : proc

extrn JpfbtpThunkExceptionHandler@16 : proc
extrn JpfbtpUnwindThunkstack@16 : proc
extrn JpfbtpInstallExceptionHandler@8 : proc
extrn JpfbtpUninstallExceptionHandler@4 : proc

ifndef JPFBT_TARGET_USERMODE
extrn JpfbtpAcquireCurrentThread@0 : proc
extrn JpfbtpReleaseCurrentThread@0 : proc
endif

ifdef JPFBT_TARGET_USERMODE
extrn RaiseException@16 : proc
else
extrn ExRaiseStatus@4 : proc
extrn KeBugCheck@4 : proc
endif

;
; Put JpfbtpThunkExceptionHandlerThunk in the SafeSEH table.
;
JpfbtpThunkExceptionHandlerThunk proto
JpfbtpUnwindThunkstackThunk proto

.SAFESEH JpfbtpThunkExceptionHandlerThunk
.SAFESEH JpfbtpUnwindThunkstackThunk

;
; Helper equates for JPFBT_THUNK_STACK_FRAME
;
ProcedureOffset					EQU 0
ReturnAddressOffset				EQU 4
SehRecordOffset					EQU 8

SizeofStackFrame				EQU 20

STATUS_FBT_NO_THUNKSTACK		EQU 80049200h
STATUS_FBT_REENTRANT_EXIT		EQU 80049214h
STATUS_FBT_THUNKSTACK_UNDERFLOW	EQU 80049215h
STATUS_STACK_OVERFLOW			EQU 0C00000FDh

EXCEPTION_FBT_NO_THUNKSTACK		EQU 80049200h
EXCEPTION_STACK_OVERFLOW		EQU 0C00000FDh
EXCEPTION_NONCONTINUABLE		EQU 1

.data
.code

ASSUME FS:NOTHING

;++
;	Routine Description:
;		Exception handler. Delegates to JpfbtpThunkExceptionHandler.
;		We just delcare it here so we can have ML register it as a
;		SafeSEH handler for us.
;--
JpfbtpThunkExceptionHandlerThunk proc
	jmp JpfbtpThunkExceptionHandler@16
JpfbtpThunkExceptionHandlerThunk endp

;++
;	Routine Description:
;		Exception handler. Delegates to JpfbtpUnwindThunkstack.
;		We just delcare it here so we can have ML register it as a
;		SafeSEH handler for us.
;--
JpfbtpUnwindThunkstackThunk proc
	jmp JpfbtpUnwindThunkstack@16
JpfbtpUnwindThunkstackThunk endp


;++
;	Routine Description:
;		Called instead of hooked function. 
;
;		This function has an unknown calling convention (may
;		be either cdecl, stdcall or fastcall) and never returns by
;		itself. All registers are left unchanged.
;
;	Stack Parameters:
;		Funcptr
;
;	Return Value:
;		Never returns, jumps to hooked function
;--
JpfbtpFunctionEntryThunk proc
	push ebp
	mov ebp, esp
	
	push eax				; scratch register
	push ecx				; scratch register
	push edx				; scratch register
	
	;
	; Swap return addresses s.t. the hooked procedure returns to 
	; the call thunk rather than to the caller.
	;
	; N.B. Modifying the return address interferes with the CPU's return 
	; address predictor - the CPU will not like it and there will be
	; a performance penalty, but this is the price to pay...
	;
	; Stack Before:         Stack After:
	;  saved edx	<-SP	 saved edx	<-SP
	;  saved ecx			 saved ecx
	;  saved eax			 saved eax
	;  saved ebp	<-BP	 saved ebp	<-BP
	;  Thunk RA				 Real RA
	;  Funcptr				 Funcptr
	;  Real RA				 Thunk RA
	;  Parameters			 Parameters	
	;
	mov eax, [ebp+4]		; Thunk RA
	mov edx, [ebp+12]		; Real RA
	mov [ebp+12], eax
	mov [ebp+4], edx
	
	;
	; Register state:
	;  eax: free
	;  ecx: free
	;  edx: free
	;
	
	;
	; Protect against reentrance.
	;
ifndef JPFBT_TARGET_USERMODE
	call JpfbtpAcquireCurrentThread@0
	test eax, 1
	jz ReentrantEntry			; if FALSE, acquiration failed
endif

	;
	; Get thunkstack.
	;
	; N.B. All volatiles are free.
	;
	call JpfbtpGetCurrentThunkStack@0
	
	test eax, eax			; Check that we have got a stack
	jz NoStack
	
	mov ecx, [eax]			; ecx = thunkstack->StackPointer

	;
	; Register state:
	;  eax: thunkstack
	;  ecx: thunkstack->StackPointer
	;  edx: free
	;	
	
	;
	; Check if stack has enough free space.
	; The stack overflows if thunkstack->StackPointer would be
	; overwritten.
	;
	lea edx, [ecx - SizeofStackFrame]
	cmp edx, eax
	jle StackOverflow
	
	;
	; stash away funcptr on thunkstack.
	;
	mov edx, [ebp+8]
	mov [ecx - SizeofStackFrame + ProcedureOffset], edx
	
	;
	; stash away Real RA on thunkstack.
	;
	mov edx, [ebp+4]
	mov [ecx - SizeofStackFrame + ReturnAddressOffset], edx
	
	;
	; Install our SEH handler.
	;
	lea edx, [ecx - SizeofStackFrame]	
	push eax						; Preserve.
	push ecx						; Preserve.
	push edx						; Frame being set up.
	push fs:[0]						; TopRecord
	call JpfbtpInstallExceptionHandler@8
	
	test eax, 1						; if FALSE, we have to give up.

	pop ecx							; Restore.
	pop eax							; Restore.
	
	jz ExcpHandlerInstallationFailed
	
	;
	; Adjust stack pointer:
	;   thunkstack->StackPointer--
	;
	lea edx, [ecx - SizeofStackFrame]
	mov [eax], edx			
	
	;
	; Register state:
	;  eax: free
	;  ecx: free
	;  edx: free
	;
	
	;
	; Prepare call to JpfbtpProcedureEntry.
	;	
	; Initialize JPFBT_CONTEXT.
	;
	sub esp, 028h			; sizeof( JPFBT_CONTEXT )
	
	mov [esp+00h], edi
	mov [esp+04h], esi
	mov [esp+08h], ebx
	push [ebp-00Ch]			; edx was preserved
	pop [esp+00Ch]			; 
	push [ebp-08h]			; ecx was preserved
	pop [esp+010h]			;
	push [ebp-04h]			; eax was preserved
	pop [esp+014h]			;
	
	push [ebp]				; ebp was preserved
	pop [esp+018h]
	push [ebp+8]			; use funcptr as EIP
	pop [esp+01Ch]			;
	pushfd
	pop [esp+020h]
	lea eax, [ebp+0Ch]		; Calculate original esp
	mov [esp+024h], eax

	;
	; Push parameters for JpfbtpProcedureEntry.
	;
	push [ebp+8]			; funcptr
	lea eax, [esp+4]		
	push eax				; &Context 

	call JpfbtpProcedureEntry@8
	
ifdef JPFBT_TARGET_KERNELMODE	
	;
	; Release reentrance protection.
	;
	call JpfbtpReleaseCurrentThread@0
endif

	;
	; Tear down CONTEXT.
	;
	add esp, 028h	; sizeof( JPFBT_CONTEXT ) 
	
JumpToTarget:
	
	mov eax, [ebp+8]		; Funcptr
	add eax, 2				; skip overwritten part of prolog
	mov [ebp+8], eax
		
	pop edx
	pop ecx
	pop eax
	pop ebp	

	add esp, 4
	ret						; Funcptr is at [esp].
	
ExcpHandlerInstallationFailed:
	;
	; Do the same as when the stack is depleted - continue without 
	; interception.
	;
	; Release thread and continue without interception.
	;
	
NoStack:
	;
	; We have not been able to retrieve a thunkstack, so intercepting
	; this procedure is not possible. We thus undo our changes made,
	; i.e. re-adjust esp, restore registers and - most importantly -
	; restore the original return address.
	;
	; Release thread and continue without interception.
	;
ifndef JPFBT_TARGET_USERMODE
	call JpfbtpReleaseCurrentThread@0
endif
	
ReentrantEntry:
	;
	; To avoid nasty reentrancy issues, do not intercept this call.
	;
	; N.B. The thread has not been acquired.
	;

	mov eax, [ebp+4]		; Real RA
	mov [ebp+12], eax		; restore real RA
	
	jmp JumpToTarget
	
StackOverflow:
ifdef JPFBT_TARGET_USERMODE
	push 0					; lpArguments
	push 0					; nNumberOfArguments
	push EXCEPTION_NONCONTINUABLE
	push EXCEPTION_STACK_OVERFLOW
	call RaiseException@16
else
	push STATUS_STACK_OVERFLOW
	call KeBugCheck@4
endif
JpfbtpFunctionEntryThunk endp

;++
;	Routine Description:
;		Thunk called by patched prolog of hooked function.
;
;		This function is basically naked, i.e. it has no parameters and
;		does not clean up the stack. All registers are left unchanged.
;
;	Parameters
;		None
;
;	Return Value:
;		No own return value, preserved value returned by hooked
;		function.
;--
JpfbtpFunctionCallThunk proc
	call JpfbtpFunctionEntryThunk

	;
	; N.B. This routine assumes that the stack above the SP (for
	; cdecl, this is the space where the locals have been; for 
	; stdcall, this is the space where the parameters are) can
	; be used, i.e. the caller will not read from this space.
	;
	; Judging from compiler observation, this assuption seems
	; to be safe.
	;
	; This routine preserves all register values.
	
	;
	; Reserve space for return address.
	;
	push 0;
	
	;
	; Setup frame.
	;	
	push ebp
	mov ebp, esp
	
	push eax
	push ecx
	push edx

	;
	; Now we have a stack frame.
	;
	; Stack:
	;   preserved edx		<- SP
	;   preserved ecx
	;   preserved eax
	;   preserved ebp		<- BP
	;   0 (reserved)
	;   ???                 <- original SP
	;   ???
	;

ifndef JPFBT_TARGET_USERMODE	
	;
	; Acquire reentrance protection. Note that we only have to
	; protect against reentrant entries. If entries are avoided while
	; we are handling an exit, we are implicitly protected against
	; reentrant exits.
	;
	call JpfbtpAcquireCurrentThread@0	; will always return TRUE
	test eax, 1
	jz ReentrantEntry					; if FALSE, acquiration failed
endif
	
	;
	; Get thunkstack.
	;
	; N.B. All volatiles are free.
	;
	call JpfbtpGetCurrentThunkStack@0
	
	test eax, eax			; Check that we have got a stack
	jz NoStack
	
	mov ecx, [eax]			; ecx = thunkstack->StackPointer
	
	;
	; Register state:
	;  eax: thunkstack
	;  ecx: thunkstack->StackPointer
	;  edx: free
	;	
	
	;
	; Restore RA. Use the space reserved earlier.
	;
	mov edx, [ecx + ReturnAddressOffset]	; Get RA address.
	cmp edx, 0deadbeefh
	je StackUnderflow
	
	mov [ebp+4], edx						; Write to reserved slot.
	
	;
	; Uninstall our SEH handler.
	;
	push eax								; Preserve.
	push edx								; Preserve.
	push ecx								; Preserve.
	push ecx								; Frame.
	call JpfbtpUninstallExceptionHandler@4
	pop ecx									; Restore.
	pop edx									; Restore.
	pop eax									; Restore.
	
	;
	; Register state:
	;  eax: free
	;  ecx: thunkstack->StackPointer
	;  edx: funcptr
	;
	
	;
	; Retrieve funcptr.
	;
	mov edx, [ecx + ProcedureOffset]
	
	;
	; Adjust stack pointer:
	;   thunkstack->StackPointer++
	;
	lea ecx, [ecx + SizeofStackFrame]
	mov [eax], ecx
	
	;
	; Register state:
	;  eax: free
	;  ecx: free
	;  edx: funcptr
	;
	
	;
	; Prepare call to JpfbtpProcedureExit.
	;
	; Initialize JPFBT_CONTEXT.
	;
	sub esp, 028h			; sizeof( JPFBT_CONTEXT )
	
	mov [esp+000h], edi
	mov [esp+004h], esi
	mov [esp+008h], ebx
	push [ebp-0Ch]			; edx was preserved
	pop [esp+00Ch]			; 
	push [ebp-08h]			; ecx was preserved
	pop [esp+010h]			;
	push [ebp-04h]			; eax was preserved
	pop [esp+014h]			;
	
	push [ebp]				; ebp was preserved
	pop [esp+018h]
	mov [esp+01Ch], edx		; use funcptr as EIP
	
	pushfd
	pop [esp+020h]
	
	push [ebp+8]			; esp was preserved
	pop [esp+024h]
	
	;
	; Push parameters for JpfbtpProcedureExit
	;
	push edx				; funcptr
	lea eax, [esp+4h]
	push eax				; &Context

	call JpfbtpProcedureExit@8
	
ifdef JPFBT_TARGET_KERNELMODE	
	call JpfbtpReleaseCurrentThread@0
endif
	
	; Tear down CONTEXT.
	add esp, 028h	; sizeof( JPFBT_CONTEXT )
	
	;
	; Restore volatiles.
	;
	pop edx
	pop ecx
	pop eax
	pop ebp
	
	;
	; The return address is now at [esp], so a ret will do.
	;
	ret

NoStack:
	;
	; Now we are in trouble - being in this procedure means
	; that JpfbtpFunctionEntryThunk was able to obtain a stack,
	; yet we did not get one. This must never happen, thus bail out.
	;
ifdef JPFBT_TARGET_USERMODE
	push 0					; lpArguments
	push 0					; nNumberOfArguments
	push EXCEPTION_NONCONTINUABLE
	push EXCEPTION_FBT_NO_THUNKSTACK
	call RaiseException@16	
else
	push STATUS_FBT_NO_THUNKSTACK
	call KeBugCheck@4
endif

ReentrantEntry:
ifdef JPFBT_TARGET_KERNELMODE
	push STATUS_FBT_REENTRANT_EXIT
	call KeBugCheck@4
endif
	
StackUnderflow:
ifdef JPFBT_TARGET_USERMODE
	push 0					; lpArguments
	push 0					; nNumberOfArguments
	push EXCEPTION_NONCONTINUABLE
	push STATUS_FBT_THUNKSTACK_UNDERFLOW
	call RaiseException@16	
else
	push STATUS_FBT_THUNKSTACK_UNDERFLOW
	call KeBugCheck@4
endif
	
JpfbtpFunctionCallThunk endp

END