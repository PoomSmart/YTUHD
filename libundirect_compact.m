// Copyright (c) 2020-2022 Lars Fröder

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <PSHeader/Misc.h>

typedef enum 
{ 
    OPTION_DO_NOT_SEEK_BACK = 1 << 0
} libundirect_find_options_t;

#define HBLogDebugWeak(...)

NSString* _libundirect_getSelectorString(Class _class, SEL selector)
{
    NSString* prefix;

    if(class_isMetaClass(_class))
    {
        prefix = @"+";
    }
    else
    {
        prefix = @"-";
    }

    return [NSString stringWithFormat:@"%@[%@ %@]", prefix, NSStringFromClass(_class), NSStringFromSelector(selector)];
}

//only on ios

#import <substrate.h>

NSMutableDictionary* undirectedSelectorsAndValues;
NSMutableArray* failedSelectors;

void libundirect_MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old)
{
    HBLogDebugWeak(@"libundirect_MSHookMessageEx(%@, %@)", NSStringFromClass(_class), NSStringFromSelector(message));
    if(undirectedSelectorsAndValues)
    {
        if(message)
        {
            NSString* selectorString = _libundirect_getSelectorString(_class, message);

            NSValue* symbol = [undirectedSelectorsAndValues objectForKey:selectorString];
            if(symbol)
            {
                void* symbolPtr = [symbol pointerValue];

                HBLogDebugWeak(@"received hook for %@ which is a direct method, hooking...", selectorString);
                MSHookFunction(symbolPtr, (void *)hook, (void **)old);
                return;
            }
        }
    }

    MSHookMessageEx(_class, message, hook, old);
}

//only on ios end

int _libundirect_dyldIndexForImageName(NSString* imageName)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
    {
        const char *pathC = _dyld_get_image_name(i);
        NSString* path = [NSString stringWithUTF8String:pathC];
        NSString* cImageName = [path lastPathComponent];

        if([cImageName isEqualToString:imageName])
        {
            return i;
        }
    }

    return -1;
}

void _libundirect_addToFailedSelectors(NSString* selectorString)
{
    static dispatch_once_t onceToken;
    dispatch_once (&onceToken, ^{
        failedSelectors = [NSMutableArray new];
    });

    [failedSelectors addObject:selectorString];
}

void libundirect_rebind(void* directPtr, Class _class, SEL selector, const char* format)
{
    NSString* selectorString = _libundirect_getSelectorString(_class, selector);

    HBLogDebugWeak(@"about to apply %@ with %s to %p", selectorString, format, directPtr);

    static dispatch_once_t onceToken;
    dispatch_once (&onceToken, ^{
        undirectedSelectorsAndValues = [NSMutableDictionary new];
    });

    if([undirectedSelectorsAndValues objectForKey:selectorString])
    {
        // check if the selector has already been undirected
        // in that case, just return as it may incorrectly get added to failed selectors otherwise
        return;
    }

    // check whether the direct pointer is actually a valid function pointer
    Dl_info info;
    int rc = dladdr(directPtr, &info);

    if(rc == 0)
    {
        HBLogDebugWeak(@"failed, not a valid function pointer");
        _libundirect_addToFailedSelectors(selectorString);
        return;
    }

    class_addMethod(
        _class, 
        selector,
        (IMP)make_sym_callable(directPtr), 
        format
    );

    NSValue* ptrValue = [NSValue valueWithPointer:directPtr];
    [undirectedSelectorsAndValues setObject:ptrValue forKey:selectorString];

    HBLogDebugWeak(@"%@ applied", selectorString);
}

int memcmp_masked(const void *str1, const void *str2, unsigned char* mask, size_t n)
{
    const unsigned char* p = (const unsigned char*)str1;
    const unsigned char* q = (const unsigned char*)str2;

    if(p == q) return 0;

    for(int i = 0; i < n; i++)
    {
        unsigned char cMask = mask[i];
        if((p[i] & cMask) != (q[i] & cMask))
        {
            // we do not care about 1 / -1
            return -1;
        }
    }

    return 0;
}

void* _libundirect_find_in_region(vm_address_t startAddr, vm_offset_t regionLength, unsigned char* bytesToSearch, unsigned char* byteMask, size_t byteCount)
{
    if(byteCount < 1)
    {
        return NULL;
    }

    unsigned int firstByteIndex = 0;
    if(byteMask != NULL)
    {
        for(size_t i = 0; i < byteCount; i++)
        {
            if(byteMask[i] == 0xFF)
            {
                firstByteIndex = i;
                break;
            }
        }
    }

    unsigned char firstByte = bytesToSearch[firstByteIndex];
    vm_address_t curAddr = startAddr;

    while(curAddr < startAddr + regionLength)
    {
        size_t searchSize = (startAddr - curAddr) + regionLength;
        void* foundPtr = memchr((void*)curAddr,firstByte,searchSize);

        if(foundPtr == NULL)
        {
            HBLogDebugWeak(@"foundPtr == NULL return");
            break;
        }
        
        vm_address_t foundAddr = (vm_address_t)foundPtr;

        // correct foundPtr in respect of firstByteIndex
        foundPtr = (void*)((intptr_t)foundPtr - firstByteIndex);        

        size_t remainingBytes = regionLength - (foundAddr - startAddr);

        if(remainingBytes >= byteCount)
        {
            int memcmp_res;
            if(byteMask != NULL)
            {
                memcmp_res = memcmp_masked(foundPtr, bytesToSearch, byteMask, byteCount);
            }
            else
            {
                memcmp_res = memcmp(foundPtr, bytesToSearch, byteCount);
            }

            if(memcmp_res == 0)
            {
                HBLogDebugWeak(@"foundPtr = %p", foundPtr);
                return foundPtr;
            }
        }
        else
        {
            break;
        }

        curAddr = foundAddr + 1;
    }

    return NULL;
}

void* libundirect_seek_back(void* startPtr, unsigned char toByte, unsigned int maxSearch)
{
    vm_address_t startAddr = (vm_address_t)startPtr;
    vm_address_t curAddr = startAddr;

    while((startAddr - curAddr) < maxSearch)
    {
        void* curPtr = (void*)curAddr;
        unsigned char curChar = *(unsigned char*)curPtr;

        if(curChar == toByte)
        {
            return curPtr;
        }

        curAddr = curAddr - 1;
    }

    return NULL;
}

void* libundirect_find_with_options_and_mask(NSString* imageName, unsigned char* bytesToSearch, unsigned char* byteMask, size_t byteCount, unsigned char startByte, unsigned int seekbackMax, libundirect_find_options_t options)
{
    int imageIndex = _libundirect_dyldIndexForImageName(imageName);
    if(imageIndex == -1)
    {
        return NULL;
    }

    intptr_t baseAddr = _dyld_get_image_vmaddr_slide(imageIndex);
    struct mach_header_64* header = (struct mach_header_64*)_dyld_get_image_header(imageIndex);

    const struct segment_command_64* cmd;

    uintptr_t addr = (uintptr_t)(header + 1);
    uintptr_t endAddr = addr + header->sizeofcmds;

    for(int ci = 0; ci < header->ncmds && addr <= endAddr; ci++)
	{
		cmd = (typeof(cmd))addr;

		addr = addr + cmd->cmdsize;

		if(cmd->cmd != LC_SEGMENT_64 || strcmp(cmd->segname, "__TEXT"))
		{
			continue;
		}

		void* result = _libundirect_find_in_region(cmd->vmaddr + baseAddr, cmd->vmsize, bytesToSearch, byteMask, byteCount);

        if(options & OPTION_DO_NOT_SEEK_BACK)
        {
            return result;
        }

        if(result != NULL)
        {
            if(startByte)
            {
                void* backResult = libundirect_seek_back(result, startByte, seekbackMax);
                if(backResult)
                {
                    return backResult;
                }
                else
                {
                    return result;
                }
            }
            else
            {
                return result;
            }
        }
	}

    return NULL;
}

void* libundirect_find_with_options(NSString* imageName, unsigned char* bytesToSearch, size_t byteCount, unsigned char startByte, unsigned int seekbackMax, libundirect_find_options_t options)
{
    return libundirect_find_with_options_and_mask(imageName, bytesToSearch, NULL, byteCount, startByte, seekbackMax, options);
}

void* libundirect_find(NSString* imageName, unsigned char* bytesToSearch, size_t byteCount, unsigned char startByte)
{
    return libundirect_find_with_options(imageName, bytesToSearch, byteCount, startByte, 64, 0);
}

void* libundirect_dsc_find(NSString* imageName, Class _class, SEL selector)
{
    NSString* symbol = _libundirect_getSelectorString(_class, selector);
    NSString* imagePath = nil;

    HBLogDebugWeak(@"searching dyldSharedCache for symbol: %@", symbol);

    int imageIndex = -1;
    if(imageName)
    {
        imageIndex = _libundirect_dyldIndexForImageName(imageName);
    }

    if(imageIndex != -1)
    {
        const char *name = _dyld_get_image_name(imageIndex);
        imagePath = [NSString stringWithUTF8String:name];
    }

    MSImageRef image = NULL;
    if(imagePath)
    {
        image = MSGetImageByName(imagePath.UTF8String);
    }

    void *symbolPtr = MSFindSymbol(image, symbol.UTF8String);
    /*HBLogDebugWeak(@"libundirect found pointer %p for symbol %@", symbolPtr, symbol);
    Dl_info info;
    dladdr(symbolPtr, &info);
    HBLogDebugWeak(@"%p: %s + 0x%llX", symbolPtr, info.dli_fname, (uint64_t)symbolPtr - (uint64_t)info.dli_fbase);*/
    return symbolPtr;
}

void libundirect_dsc_rebind(NSString* imageName, Class _class, SEL selector, const char* format)
{
    void* ptr = libundirect_dsc_find(imageName, _class, selector);
    libundirect_rebind(ptr, _class, selector, format);
}

NSArray* libundirect_failedSelectors()
{
    return [failedSelectors copy];
}
