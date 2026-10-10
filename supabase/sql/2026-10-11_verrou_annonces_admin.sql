-- =====================================================================
-- MyTunigo — Correctif de sécurité : verrou des champs d'identité des annonces
-- Projet : fxbetakueqkzipsqvtck — 11/10/2026
--
-- Le trigger prevent_annonce_identity_change empêche un hôte de modifier
-- le nom, le type, la ville, le pays, l'adresse, le code postal et la
-- position GPS d'une annonce. Il reconnaissait l'administrateur via
-- user_metadata.role : or user_metadata est MODIFIABLE par l'utilisateur
-- lui-même (supabase.auth.updateUser) — n'importe quel hôte pouvait donc
-- s'attribuer role = 'admin' dans ses métadonnées et contourner le verrou.
--
-- Correctif : l'administrateur est reconnu par fn_is_admin(), qui lit
-- app_metadata.role (non modifiable par l'utilisateur), comme partout
-- ailleurs. Le compte admin@mytunigo.com a bien app_metadata.role = 'admin'.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.prevent_annonce_identity_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
begin
  if not public.fn_is_admin() then
    if new.name    is distinct from old.name
       or new.type    is distinct from old.type
       or new.city    is distinct from old.city
       or new.country is distinct from old.country
       or new.address is distinct from old.address
       or new.zip     is distinct from old.zip
       or new.lat     is distinct from old.lat
       or new.lng     is distinct from old.lng
    then
      raise exception 'Le nom, le type, la ville, le pays, l''adresse, le code postal et la position GPS ne peuvent plus être modifiés directement. Contactez l''administrateur pour toute correction.'
        using errcode = '42501'; -- insufficient_privilege
    end if;
  end if;
  return new;
end;
$function$;
