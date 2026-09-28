/*
 * Copyright 2026 Sighter Project Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* argv: inherited socket descriptor, IP_DONTFRAG value. */

	.section .note.tag,"a",@note
	.p2align 2
	.long 8
	.long 4
	.long 1
	.asciz "FreeBSD"
	.p2align 2
	.long 1500000

	.text
	.globl _start
	.type _start,@function
_start:
	cmpq $3, (%rsp)
	jne .Lusage

	movq 16(%rsp), %rsi
	xorl %edi, %edi
.Lparse_fd:
	movzbl (%rsi), %eax
	testb %al, %al
	je .Lfd_ready
	subl $'0', %eax
	cmpl $9, %eax
	ja .Lusage
	imull $10, %edi, %edi
	addl %eax, %edi
	incq %rsi
	jmp .Lparse_fd

.Lfd_ready:
	movq 24(%rsp), %rsi
	cmpb $0, 1(%rsi)
	jne .Lusage
	movzbl (%rsi), %eax
	cmpb $'0', %al
	je .Ldisable
	cmpb $'1', %al
	jne .Lusage
	movl $1, %eax
	jmp .Lvalue_ready
.Ldisable:
	xorl %eax, %eax

.Lvalue_ready:
	subq $8, %rsp
	movl %eax, (%rsp)

	movl $105, %eax
	xorl %esi, %esi
	movl $67, %edx
	movq %rsp, %r10
	movl $4, %r8d
	syscall
	jnc .Lsuccess

	/* Retry with IPV6_DONTFRAG for dual-stack sockets. */
	movl $105, %eax
	movl $41, %esi
	movl $62, %edx
	movq %rsp, %r10
	movl $4, %r8d
	syscall
	jc .Lerror

.Lsuccess:
	xorl %edi, %edi
	jmp .Lexit
.Lerror:
	movl %eax, %edi
	andl $255, %edi
	testl %edi, %edi
	jne .Lexit
	movl $1, %edi
	jmp .Lexit
.Lusage:
	movl $64, %edi

.Lexit:
	movl $1, %eax
	syscall
	ud2
	.size _start, .-_start

	.section .note.GNU-stack,"",@progbits
