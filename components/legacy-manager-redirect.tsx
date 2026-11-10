"use client";
import {useEffect} from 'react';
import {legacyManagerDestination} from '@/lib/manager-routing.mjs';
export default function LegacyManagerRedirect(){
 useEffect(()=>{const destination=legacyManagerDestination(window.location.href);if(destination)window.location.replace(destination)},[]);
 return null;
}
