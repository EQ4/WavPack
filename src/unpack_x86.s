############################################################################
##                           **** WAVPACK ****                            ##
##                  Hybrid Lossless Wavefile Compressor                   ##
##              Copyright (c) 1998 - 2015 Conifer Software.               ##
##                          All Rights Reserved.                          ##
##      Distributed under the BSD Software License (see license.txt)      ##
############################################################################

        .intel_syntax noprefix
        .text
        .globl  unpack_decorr_stereo_pass_cont_x86

# This is an assembly optimized version of the following WavPack function:
#
# void unpack_decorr_stereo_pass_cont (struct decorr_pass *dpp,
#                                      int32_t *buffer,
#                                      int32_t sample_count,
#                                      int32_t long_math;
#
# It performs a single pass of stereo decorrelation on the provided buffer.
# Note that this version of the function requires that up to 8 previous
# stereo samples are visible and correct. In other words, it ignores the
# "samples_*" fields in the decorr_pass structure and gets the history data
# directly from the buffer. It does, however, return the appropriate history
# samples to the decorr_pass structure before returning.
#
# The "long_math" argument is used to specify that a 32-bit multiply is
# not enough for the "apply_weight" operation, although in this case it
# only applies to the -1 and -2 terms because the MMX code does not have
# this limitation.
#
# This is written to work on an IA-32 processor and uses the MMX extensions
# to improve the performance by processing both stereo channels together.
# For terms -1 and -2 the MMX extensions are not usable, and so these are
# performed independently without them.
#
# arguments on entry:
#
#   struct decorr_pass *dpp     [ebp+8]
#   int32_t *buffer             [ebp+12]
#   int32_t sample_count        [ebp+16]
#   int32_t long_math           [ebp+20]
#
# registers after entry:
#
#   rdi         bptr
#   rsi         eptr
#
# on stack (used for terms -1 and -2 only):
# 
#   int32_t delta             DWORD [esp]
#

unpack_decorr_stereo_pass_cont_x86:
        push    ebp
        mov     ebp, esp
        push    ebx
        push    esi
        push    edi

        mov     edx, [ebp+8]                # copy delta from dpp to top of stack
        mov     eax, [edx+4]
        push    eax

        mov     edi, [ebp+12]               # edi = buffer
        mov     eax, [ebp+16]               # get sample_count and divide by 8
        sal     eax, 3
        jz      done                        # exit now if there's nothing to do

        add     eax, edi                    # else add to buffer point to make eptr
        mov     esi, eax
    
        mov     eax, [ebp+8]                # get term from dpp and vector appropriately
        mov     eax, [eax]
        cmp     eax, 17
        je      term_17_entry
        cmp     eax, 18
        je      term_18_entry
        cmp     eax, -1
        je      term_minus_1_entry
        cmp     eax, -2
        je      term_minus_2_entry
        cmp     eax, -3
        je      term_minus_3_entry

#
# registers during default term processing loop:
#   edi         active buffer pointer
#   esi         end of buffer pointer
#
# MMX:
#   mm0, mm1    scratch
#   mm2         original sample values
#   mm3         correlation samples
#   mm4         zero (for pcmpeqd)
#   mm5         weights
#   mm6         delta
#   mm7         512 (for rounding)
#

default_term_entry:
        mov     edx, [ebp+8]                # edx = *dpp
        mov     eax, [edx]                  # set ebx to term * -8 for decorrelation index
        sal     eax, 3
        neg     eax
        mov     ebx, eax
        mov     eax, 512
        movd    mm7, eax
        punpckldq mm7, mm7                  # mm7 = round (512)
        mov     eax, [edx+4]
        movd    mm6, eax
        punpckldq mm6, mm6                  # mm6 = delta (0-7)
        mov     eax, 0xFFFF                 # mask high weights to zero for PMADDWD
        movd    mm5, eax
        punpckldq mm5, mm5                  # mm5 = weight mask 0x0000FFFF0000FFFF
        pand    mm5, [edx+8]                # mm5 = weight_AB masked to 16 bits
        pxor    mm4, mm4                    # mm4 = zero (for pcmpeqd)
        jmp     default_term_loop

        .align  64
default_term_loop:
        movq    mm3, [edi+ebx]              # mm3 = sam_AB
        movq    mm1, mm3
        movq    mm0, mm3
        paddd   mm1, mm1
        psrld   mm0, 15
        psrlw   mm1, 1
        pmaddwd mm0, mm5
        pmaddwd mm1, mm5
        movq    mm2, [edi]                  # mm2 = left_right
        pslld   mm0, 5
        paddd   mm1, mm7                    # add 512 for rounding
        psrad   mm1, 10
        paddd   mm0, mm2
        paddd   mm0, mm1                    # add shifted sums
        movq    [edi], mm0                  # store result
        movq    mm0, mm3
        pxor    mm0, mm2
        psrad   mm0, 31                     # mm0 = sign (sam_AB ^ left_right)
        add     edi, 8
        pcmpeqd mm2, mm4                    # mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm4                    # mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    # mm2 = 1s if either was zero
        pandn   mm2, mm6                    # mask delta with zeros check
        pxor    mm5, mm0
        paddw   mm5, mm2                    # and add to weight_AB
        pxor    mm5, mm0
        cmp     edi, esi                    # compare bptr and eptr to see if we're done
        jb      default_term_loop

        pslld   mm5, 16                     # sign-extend 16-bit weights back to dwords
        psrad   mm5, 16
        mov     eax, [ebp+8]                # point to dpp
        movq    [eax+8], mm5                # put weight_AB back
        emms
        mov     edx, [ebp+8]                # access dpp with edx
        mov     ecx, [edx]                  # ecx = dpp->term

default_store_samples:
        dec     ecx
        sub     edi, 8                      # back up one full sample
        mov     eax, [edi+4]
        mov     [edx+ecx*4+48], eax         # store samples_B [ecx]
        mov     eax, [edi]
        mov     [edx+ecx*4+16], eax         # store samples_A [ecx]
        test    ecx, ecx
        jnz     default_store_samples

        jmp     done

#
# registers during processing loop for terms 17 & 18:
#   edi         active buffer pointer
#   esi         end of buffer pointer
#
# MMX:
#   mm0, mm1    scratch
#   mm2         original sample values
#   mm3         calculated correlation samples
#   mm4         last calculated values (so we don't need to reload)
#   mm5         weights
#   mm6         delta
#   mm7         512 (for rounding)
#

term_17_entry:
        mov     eax, 512
        movd    mm7, eax
        punpckldq mm7, mm7                  # mm7 = round (512)
        mov     edx, [ebp+8]                # point to dpp & get delta
        mov     eax, [edx+4]
        movd    mm6, eax
        punpckldq mm6, mm6                  # mm6 = delta (0-7)
        mov     eax, 0xFFFF                 # mask high weights to zero for PMADDWD
        movd    mm5, eax
        punpckldq mm5, mm5                  # mm5 = weight mask 0x0000FFFF0000FFFF
        pand    mm5, [edx+8]                # mm5 = weight_AB masked to 16 bits
        movq    mm4, [edi-8]                # preload previous calculated values
        jmp     term_17_loop

        .align  64
term_17_loop:
        paddd   mm4, mm4
        psubd   mm4, [edi-16]               # mm3 = sam_AB
        movq    mm3, mm4
        movq    mm1, mm3
        paddd   mm1, mm1
        psrld   mm4, 15
        psrlw   mm1, 1
        pmaddwd mm4, mm5
        pmaddwd mm1, mm5
        movq    mm2, [edi]                  # mm2 = left_right
        pslld   mm4, 5
        paddd   mm1, mm7                    # add 512 for rounding
        psrad   mm1, 10
        paddd   mm4, mm2
        paddd   mm4, mm1                    # add shifted sums
        movq    mm0, mm3
        movq    [edi], mm4                  # store result
        pxor    mm0, mm2
        psrad   mm0, 31                     # mm0 = sign (sam_AB ^ left_right)
        add     edi, 8
        pxor    mm1, mm1                    # mm1 = zero
        pcmpeqd mm2, mm1                    # mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    # mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    # mm2 = 1s if either was zero
        pandn   mm2, mm6                    # mask delta with zeros check
        pxor    mm5, mm0
        paddw   mm5, mm2                    # and add to weight_AB
        pxor    mm5, mm0
        cmp     edi, esi                    # compare bptr and eptr to see if we're done
        jb      term_17_loop

        pslld   mm5, 16                     # sign-extend 16-bit weights back to dwords
        psrad   mm5, 16
        mov     eax, [ebp+8]                # point to dpp
        movq    [eax+8], mm5                # put weight_AB back
        emms
        jmp     term_1718_exit

term_18_entry:
        mov     eax, 512
        movd    mm7, eax
        punpckldq mm7, mm7                  # mm7 = round (512)
        mov     edx, [ebp+8]                # point to dpp & get delta
        mov     eax, [edx+4]
        movd    mm6, eax
        punpckldq mm6, mm6                  # mm6 = delta (0-7)
        mov     eax, 0xFFFF                 # mask high weights to zero for PMADDWD
        movd    mm5, eax
        punpckldq mm5, mm5                  # mm5 = weight mask 0x0000FFFF0000FFFF
        pand    mm5, [edx+8]                # mm5 = weight_AB masked to 16 bits
        movq    mm4, [edi-8]                # preload previous calculated value
        jmp     term_18_loop

        .align  64
term_18_loop:
        movq    mm3, mm4
        psubd   mm3, [edi-16]
        psrad   mm3, 1
        paddd   mm3, mm4                    # mm3 = sam_AB
        movq    mm1, mm3
        movq    mm4, mm3
        paddd   mm1, mm1
        psrld   mm4, 15
        psrlw   mm1, 1
        pmaddwd mm4, mm5
        pmaddwd mm1, mm5
        movq    mm2, [edi]                  # mm2 = left_right
        pslld   mm4, 5
        paddd   mm1, mm7                    # add 512 for rounding
        psrad   mm1, 10
        paddd   mm4, mm2
        paddd   mm4, mm1                    # add shifted sums
        movq    mm0, mm3
        movq    [edi], mm4                  # store result
        pxor    mm0, mm2
        psrad   mm0, 31                     # mm0 = sign (sam_AB ^ left_right)
        add     edi, 8
        pxor    mm1, mm1                    # mm1 = zero
        pcmpeqd mm2, mm1                    # mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    # mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    # mm2 = 1s if either was zero
        pandn   mm2, mm6                    # mask delta with zeros check
        pxor    mm5, mm0
        paddw   mm5, mm2                    # and add to weight_AB
        pxor    mm5, mm0
        cmp     edi, esi                    # compare bptr and eptr to see if we're done
        jb      term_18_loop

        pslld   mm5, 16                     # sign-extend 16-bit weights back to dwords
        psrad   mm5, 16
        mov     eax, [ebp+8]                # point to dpp
        movq    [eax+8], mm5                # put weight_AB back
        emms

term_1718_exit:
        mov     edx, [edi-4]                # dpp->samples_B [0] = bptr [-1];
        mov     eax, [ebp+8]
        mov     [eax+48], edx
        mov     edx, [edi-8]                # dpp->samples_A [0] = bptr [-2];
        mov     [eax+16], edx
        mov     edx, [edi-12]               # dpp->samples_B [1] = bptr [-3];
        mov     [eax+52], edx
        mov     edx, [edi-16]               # dpp->samples_A [1] = bptr [-4];
        mov     [eax+20], edx
        jmp     done

#
# registers in term -1 & -2 loops:
#
#   eax,ebx,edx scratch
#   ecx         weight_A
#   ebp         weight_B
#   edi         bptr
#   esi         eptr
#

term_minus_1_entry:
        cld                                 # we use stosd here...
        cmp     DWORD PTR [ebp+20], 0       # test long_math
        mov     eax, [ebp+8]                # point to dpp
        mov     ecx, [eax+8]                # ecx = weight_A and ebp = weight_B
        mov     ebp, [eax+12]
        mov     eax, [edi-4]
        jnz     long_term_minus_1_loop
        jmp     term_minus_1_loop

        .align  64
term_minus_1_loop:
        mov     ebx, eax
        imul    eax, ecx
        sar     eax, 10
        mov     edx, [edi]
        adc     eax, edx
        stosd
        test    ebx, ebx
        je      L182
        test    edx, edx
        je      L182
        xor     ebx, edx
        sar     ebx, 31
        xor     ecx, ebx
        add     ecx, [esp]
        mov     edx, 1024
        add     edx, ebx
        cmp     ecx, edx
        jle     L183
        mov     ecx, edx
L183:   xor     ecx, ebx
L182:   mov     ebx, eax
        imul    eax, ebp
        sar     eax, 10
        mov     edx, [edi]
        adc     eax, edx
        stosd
        test    ebx, ebx
        je      L189
        test    edx, edx
        je      L189
        xor     ebx, edx
        sar     ebx, 31
        xor     ebp, ebx
        add     ebp, [esp]
        mov     edx, 1024
        add     edx, ebx
        cmp     ebp, edx
        jle     L188
        mov     ebp, edx
L188:   xor     ebp, ebx
L189:   cmp     edi, esi                    # compare bptr and eptr to see if we're done
        jb      term_minus_1_loop
        jmp     term_minus_1_done

        .align  64
long_term_minus_1_loop:
        mov     ebx, eax
        imul    ecx
        shl     edx, 22
        shr     eax, 10
        adc     eax, edx
        mov     edx, [edi]
        add     eax, edx
        stosd
        test    ebx, ebx
        je      L282
        test    edx, edx
        je      L282
        xor     ebx, edx
        sar     ebx, 31
        xor     ecx, ebx
        add     ecx, [esp]
        mov     edx, 1024
        add     edx, ebx
        cmp     ecx, edx
        jle     L283
        mov     ecx, edx
L283:   xor     ecx, ebx
L282:   mov     ebx, eax
        imul    ebp
        shl     edx, 22
        shr     eax, 10
        adc     eax, edx
        mov     edx, [edi]
        add     eax, edx
        stosd
        test    ebx, ebx
        je      L289
        test    edx, edx
        je      L289
        xor     ebx, edx
        sar     ebx, 31
        xor     ebp, ebx
        add     ebp, [esp]
        mov     edx, 1024
        add     edx, ebx
        cmp     ebp, edx
        jle     L288
        mov     ebp, edx
L288:   xor     ebp, ebx
L289:   cmp     edi, esi                    # compare bptr and eptr to see if we're done
        jb      long_term_minus_1_loop

term_minus_1_done:
        mov     edx, ebp
        mov     ebp, esp                    # restore ebp (we've pushed 4 DWORDS)
        add     ebp, 16
        mov     eax, [ebp+8]                # point to dpp
        mov     [eax+8], ecx
        mov     [eax+12], edx
        mov     edx, [edi-4]                # dpp->samples_A [0] = bptr [-1]
        mov     [eax+16], edx
        jmp     done


term_minus_2_entry:
        cmp     DWORD PTR [ebp+20], 0       # test long_math
        mov     eax, [ebp+8]                # point to dpp
        mov     ecx, [eax+8]                # ecx = weight_A and ebp = weight_B
        mov     ebp, [eax+12]
        mov     eax, [edi-8]
        jnz     long_term_minus_2_loop
        jmp     term_minus_2_loop

        .align  64
term_minus_2_loop:
        mov     ebx, eax
        imul    eax, ebp
        sar     eax, 10
        mov     edx, [edi+4]
        adc     eax, edx
        mov     [edi+4], eax
        test    ebx, ebx
        je      L194
        test    edx, edx
        je      L194
        xor     ebx, edx
        sar     ebx, 31
        xor     ebp, ebx
        add     ebp, [esp]
        mov     edx, 1024
        add     edx, ebx
        cmp     ebp, edx
        jle     L195
        mov     ebp, edx
L195:   xor     ebp, ebx
L194:   mov     ebx, eax
        imul    eax, ecx
        sar     eax, 10
        mov     edx, [edi]
        adc     eax, edx
        mov     [edi], eax
        add     edi, 8
        test    ebx, ebx
        je      L201
        test    edx, edx
        je      L201
        xor     ebx, edx
        sar     ebx, 31
        xor     ecx, ebx
        add     ecx, [esp]
        mov     edx, 1024
        add     edx, ebx
        cmp     ecx, edx
        jle     L200
        mov     ecx, edx
L200:   xor     ecx, ebx
L201:   cmp     edi, esi                    # compare bptr and eptr to see if we're done
        jb      term_minus_2_loop
        jmp     term_minus_2_done

        .align  64
long_term_minus_2_loop:
        mov     ebx, eax
        imul    ebp
        shl     edx, 22
        shr     eax, 10
        adc     eax, edx
        mov     edx, [edi+4]
        add     eax, edx
        mov     [edi+4], eax
        test    ebx, ebx
        je      L294
        test    edx, edx
        je      L294
        xor     ebx, edx
        sar     ebx, 31
        xor     ebp, ebx
        add     ebp, [esp]
        mov     edx, 1024
        add     edx, ebx
        cmp     ebp, edx
        jle     L295
        mov     ebp, edx
L295:   xor     ebp, ebx
L294:   mov     ebx, eax
        imul    ecx
        shl     edx, 22
        shr     eax, 10
        adc     eax, edx
        mov     edx, [edi]
        add     eax, edx
        mov     [edi], eax
        add     edi, 8
        test    ebx, ebx
        je      L301
        test    edx, edx
        je      L301
        xor     ebx, edx
        sar     ebx, 31
        xor     ecx, ebx
        add     ecx, [esp]
        mov     edx, 1024
        add     edx, ebx
        cmp     ecx, edx
        jle     L300
        mov     ecx, edx
L300:   xor     ecx, ebx
L301:   cmp     edi, esi                    # compare bptr and eptr to see if we're done
        jb      long_term_minus_2_loop

term_minus_2_done:
        mov     edx, ebp
        mov     ebp, esp                    # restore ebp (we've pushed 4 DWORDS)
        add     ebp, 16
        mov     eax, [ebp+8]                # point to dpp
        mov     [eax+8], ecx
        mov     [eax+12], edx
        mov     edx, [edi-8]                # dpp->samples_B [0] = bptr [-2];
        mov     [eax+48], edx
        jmp     done

#
# registers during processing loop for term -3:
#   edi         active buffer pointer
#   esi         end of buffer pointer
#
# MMX:
#   mm0, mm1    scratch
#   mm2         original sample values
#   mm3         calculated correlation samples
#   mm4         last calculated values (so we don't need to reload)
#   mm5         weights
#   mm6         delta
#   mm7         512 (for rounding)
#

term_minus_3_entry:
        mov     eax, 512
        movd    mm7, eax
        punpckldq mm7, mm7                  # mm7 = round (512)
        mov     edx, [ebp+8]                # point to dpp & get delta
        mov     eax, [edx+4]
        movd    mm6, eax
        punpckldq mm6, mm6                  # mm6 = delta (0-7)
        mov     eax, 0xFFFF                 # mask high weights to zero for PMADDWD
        movd    mm5, eax
        punpckldq mm5, mm5                  # mm5 = weight mask 0x0000FFFF0000FFFF
        pand    mm5, [edx+8]                # mm5 = weight_AB masked to 16 bits
        movq    mm4, [edi-8]                # preload previous calculated values
        jmp     term_minus_3_loop

        .align  64
term_minus_3_loop:
        movq    mm3, mm4                    # mm3 = swap dwords (mm4)
        psrlq   mm3, 32
        punpckldq mm3, mm4                  # mm3 = sam_AB
        movq    mm1, mm3
        movq    mm4, mm3
        pslld   mm1, 1
        psrld   mm4, 15
        psrlw   mm1, 1
        pmaddwd mm4, mm5
        pmaddwd mm1, mm5
        movq    mm2, [edi]                  # mm2 = left_right
        pslld   mm4, 5
        paddd   mm1, mm7                    # add 512 for rounding
        psrad   mm1, 10
        paddd   mm4, mm2
        paddd   mm4, mm1                    # add shifted sums
        movq    [edi], mm4                  # store result
        movq    mm0, mm3
        pxor    mm0, mm2
        psrad   mm0, 31                     # mm0 = sign (sam_AB ^ left_right)
        add     edi, 8
        pxor    mm1, mm1                    # mm1 = zero
        pcmpeqd mm2, mm1                    # mm2 = 1s if left_right was zero
        pcmpeqd mm3, mm1                    # mm3 = 1s if sam_AB was zero
        por     mm2, mm3                    # mm2 = 1s if either was zero
        pandn   mm2, mm6                    # mask delta with zeros check
        pcmpeqd mm1, mm1
        psubd   mm1, mm7
        psubd   mm1, mm7
        psubd   mm1, mm0
        pxor    mm5, mm0
        paddw   mm5, mm1
        paddusw mm5, mm2                    # and add to weight_AB
        psubw   mm5, mm1
        pxor    mm5, mm0
        cmp     edi, esi                    # compare bptr and eptr to see if we're done
        jb      term_minus_3_loop

        pslld   mm5, 16                     # sign-extend 16-bit weights back to dwords
        psrad   mm5, 16
        mov     eax, [ebp+8]                # point to dpp
        movq    [eax+8], mm5                # put weight_AB back
        emms
        mov     edx, [edi-4]                # dpp->samples_A [0] = bptr [-1];
        mov     eax, [ebp+8]
        mov     [eax+16], edx
        mov     edx, [edi-8]                # dpp->samples_B [0] = bptr [-2];
        mov     [eax+48], edx

done:   pop     eax                         # pop delta & saved regs
        pop     edi
        pop     esi
        pop     ebx
        pop     ebp
        ret